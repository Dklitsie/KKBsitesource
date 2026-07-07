const std = @import("std");
const root = @import("root.zig");
const log = std.log.scoped(.drive_remote);
const Request = std.http.Server.Request;
const Allocator = std.mem.Allocator;

pub const RemoteCollection = struct {
    handle: root.FileHandle,
    images: ?[]root.FileHandle,
    collections: ?[]RemoteCollection,
    template: ?root.FileHandle,

    pub fn deinit(self: *@This(), a: Allocator) void {
        self.handle.deinit(a);
        if (self.template) |*t| t.deinit(a);
        if (self.collections) |cs| {
            defer a.free(cs);
            for (cs) |*col| col.collection.deinit(a);
        }
        if (self.images) |imgs| {
            defer a.free(imgs);
        }
    }

    const TEMPLATE_FILE_NAME = "template";
    pub fn create(
        a: Allocator,
        children_by_parents: *const std.StringArrayHashMapUnmanaged(std.ArrayList(DriveFile)),
        current_path: []const u8,
        folder_handle: *const DriveFile,
    ) !RemoteCollection {
        const children = children_by_parents.get(folder_handle.id) orelse return error.NoCollection;

        var image_file_handles = try std.ArrayList(root.FileHandle).initCapacity(a, 8);
        defer image_file_handles.deinit(a);
        var child_collections = try std.ArrayList(RemoteCollection).initCapacity(a, 8);
        defer child_collections.deinit(a);
        var template: ?root.FileHandle = null;

        const template_name = blk: {
            const last_sep = std.mem.findScalarLast(u8, current_path, '/').? + 1;
            break :blk current_path[last_sep..];
        };
        for (children.items) |handle| {
            const mime = MimeOption.tryFromStr(handle.mimeType) orelse continue;

            switch (mime) {
                .folder => {
                    const nested_path = try std.fmt.allocPrint(a,
                        \\{s}/{s}
                    , .{ current_path, handle.name });
                    defer a.free(nested_path);
                    const child = try create(
                        a,
                        children_by_parents,
                        nested_path,
                        &handle,
                    );
                    try child_collections.append(a, child);
                },

                .doc => {
                    if (std.ascii.findIgnoreCase(handle.name, TEMPLATE_FILE_NAME) == null) {
                        log.err(
                            \\ Encountered unexpected doc file: '{s}'
                        , .{handle.name});
                        continue;
                    } else if (template != null) {
                        log.err(
                            \\ Encountered second template file in {s}
                        , .{folder_handle.name});
                        continue;
                    }

                    template = .{
                        .id = try a.dupe(u8, handle.id),
                        .filepath = try std.fmt.allocPrint(a, "{s}/{s}", .{ current_path, handle.name }),
                        .modifiedTime = try a.dupe(u8, handle.modifiedTime),
                        .name = try a.dupe(u8, template_name),
                        .kind = .doc,
                    };
                },
                .image => {
                    try image_file_handles.append(a, .{
                        .id = try a.dupe(u8, handle.id),
                        .filepath = try std.fmt.allocPrint(a, "{s}/{s}", .{ current_path, handle.name }),
                        .name = try a.dupe(u8, handle.name),
                        .modifiedTime = try a.dupe(u8, handle.modifiedTime),
                        .kind = .image,
                    });
                },
            }
        }

        const collection = RemoteCollection{
            .handle = .{
                .id = try a.dupe(u8, folder_handle.id),
                .filepath = try a.dupe(u8, current_path),
                .modifiedTime = try a.dupe(u8, folder_handle.modifiedTime),
                .name = try a.dupe(u8, folder_handle.name),
                .kind = .folder,
            },
            .images = if (image_file_handles.items.len > 0) try image_file_handles.toOwnedSlice(a) else null,
            .collections = if (child_collections.items.len > 0) try child_collections.toOwnedSlice(a) else null,
            .template = template,
        };

        return collection;
    }
};

pub const RemoteCollections = root.ImageCategory.Plexe(RemoteCollection, &.{
    .handle = undefined,
    .images = null,
    .collections = null,
    .template = null,
});

/// mostly for debugging
const PARENT_ID = "OUTERMOST_PARENT";
pub fn getRemoteCollections(
    a: Allocator,
    client: *std.http.Client,
    authorization_header: std.http.Client.Request.Headers.Value,
) anyerror!RemoteCollections {
    const all_files = try getDriveFiles(
        a,
        client,
        authorization_header,
    );
    defer a.free(all_files);

    var category_handles = root.ImageCategory.Plexe(?DriveFile, &null){};
    var children_by_parents = std.StringArrayHashMapUnmanaged(std.ArrayList(DriveFile)){};
    defer children_by_parents.deinit(a);

    for (all_files) |file| {
        if (std.meta.stringToEnum(root.ImageCategory, file.name)) |cat| category_handles.getField(cat).* = file;

        const parent_id =
            blk: {
                if (file.parents) |p| break :blk p[0];
                log.debug(
                    \\ File: {s} has no parent
                , .{file.name});
                break :blk PARENT_ID;
            };

        var result = try children_by_parents.getOrPut(a, parent_id);
        if (result.found_existing)
            try result.value_ptr.append(a, file)
        else {
            result.value_ptr.* = try .initCapacity(a, 8);
            result.value_ptr.appendAssumeCapacity(file);
        }
    }

    inline for (root.ImageCategory.ALL_VARIANTS) |cat| {
        if (category_handles.getFieldConst(cat).* == null) std.debug.panic(
            " Did not get id for category: {s}",
            .{@tagName(cat)},
        );
    }

    var collections = RemoteCollections{};
    inline for (root.ImageCategory.ALL_VARIANTS) |cat| {
        const handle = category_handles.getFieldConst(cat).*.?;
        collections.getField(cat).* = try RemoteCollection.create(
            a,
            &children_by_parents,
            root.DRIVE_DIR ++ "/" ++ @tagName(cat),
            &handle,
        );
    }

    return collections;
}

pub const SyncContext = struct {
    allocator: Allocator,
    io: std.Io,
    client: std.http.Client,
    auth_header: std.http.Client.Request.Headers.Value,
    files: []root.FileHandle,
    err: ?anyerror = null,

    pub fn worker(self: *@This()) void {
        for (self.files) |file| {
            switch (file.kind) {
                .image => {
                    downloadImageFile(
                        self.allocator,
                        self.io,
                        &self.client,
                        self.auth_header,
                        file,
                    ) catch |err| {
                        self.err = err;
                        break;
                    };
                },
                .doc => {
                    const body = downloadDoc(
                        self.allocator,
                        self.io,
                        &self.client,
                        self.auth_header,
                        file,
                    ) catch |err| {
                        self.err = err;
                        break;
                    };
                    self.allocator.free(body);
                },
                .folder => {
                    log.warn(
                        \\ SyncFile context encountered folder type
                        \\ skipping...
                    , .{});
                    continue;
                },
            }
        }

        if (self.err) |err| {
            log.err(
                \\ Worker for {s} encountered an error: {s}
            , .{ self.files[0].filepath, @errorName(err) });
            return;
        }
    }
};

pub fn downloadFiles(
    a: std.mem.Allocator,
    auth_header: std.http.Client.Request.Headers.Value,
    files_to_download: []root.FileHandle,
    amt_threads: usize,
) anyerror!void {
    const threads = try a.alloc(std.Thread, amt_threads);
    defer a.free(threads);
    const contexts = try a.alloc(SyncContext, amt_threads);
    defer a.free(contexts);

    var threaded_io = std.Io.Threaded.init(a, .{});
    defer threaded_io.deinit();

    const files_per_thread = files_to_download.len / amt_threads;
    const remainder = files_to_download.len % amt_threads;

    var start: usize = 0;
    for (threads, contexts, 0..) |*thread, *ctx, i| {
        const extra: usize = if (i < remainder) 1 else 0;
        const count = files_per_thread + extra;

        const end = start + count;
        const files_slice = files_to_download[start..end];
        start = end;

        const io = threaded_io.io();

        const client = std.http.Client{
            .allocator = a,
            .io = io,
            // must be explicitly set to avoid an indefinte hang
            .write_buffer_size = 1024 * 32,
        };

        ctx.* = .{
            .allocator = a,
            .io = io,
            .client = client,
            .auth_header = auth_header,
            .files = files_slice,
        };
        thread.* = try std.Thread.spawn(
            .{},
            SyncContext.worker,
            .{ctx},
        );
    }

    for (threads) |thread| {
        thread.join();
    }

    for (contexts) |ctx| {
        const err = ctx.err;
        if (err) |e| return e;
    }
}

const DriveFile = struct {
    mimeType: []u8,
    id: []u8,
    name: []u8,
    modifiedTime: []u8,
    parents: ?[][]u8 = null,
};

const DriveResponse = struct {
    files: []DriveFile,
    nextPageToken: ?[]const u8 = null,

    pub fn format(self: *const DriveResponse, w: *std.Io.Writer) std.Io.Writer.Error!void {
        w.writeAll(
            \\ Drive Response: 
        );
        for (self.files) |f| {
            try w.print(
                \\
                \\ name: {s}
                \\ id: {s}
                \\ mimeType: {s}
            , .{ f.name, f.id, f.mimeType });
            if (f.parents) |p| {
                try w.print(
                    \\ parent: {s}
                , .{p[0]});
            }
        }

        if (self.nextPageToken) |tok|
            try w.print(
                \\ next_page_token: {s}
            , .{tok});
    }
};

/// Runs a bash script to get access token
/// make sure to free authorization_header.override
pub fn createClientAndAuthHeader(a: Allocator, io: std.Io, env_map: *const std.process.Environ.Map) anyerror!struct { std.http.Client, std.http.Client.Request.Headers.Value } {
    const result = try std.process.spawn(io, .{
        .environ_map = env_map,
        .argv = &.{ "/bin/bash", "get-drive-token.sh" },
        .stdout = .pipe,
    });
    const stdout = result.stdout.?;
    var reader = stdout.reader(io, &.{});
    const stdout_txt = try reader.interface.allocRemaining(a, .unlimited);

    const access_token = std.mem.trim(u8, stdout_txt, "\n");
    log.debug("Access Token: {s}", .{access_token});

    // const access_token = env_map.get("ACCESS_TOKEN") orelse @panic("No Access Token");

    const authorization_header_str = try std.fmt.allocPrint(a, "Bearer {s}", .{access_token});
    const authorization_header = std.http.Client.Request.Headers.Value{ .override = authorization_header_str };

    const client = std.http.Client{
        .allocator = a,
        .io = io,
        // must be explicitly set to avoid an indefinte hang
        .write_buffer_size = 1024 * 32,
    };
    return .{ client, authorization_header };
}

pub const MimeOption = enum {
    folder,
    image,
    doc,

    const DRIVE_FOLDER_MIME = "application/vnd.google-apps.folder";
    const DRIVE_DOC_MIME = "application/vnd.google-apps.document";
    fn tryFromStr(str: []const u8) ?@This() {
        if (std.ascii.eqlIgnoreCase(str, DRIVE_DOC_MIME)) return .doc;
        if (std.ascii.eqlIgnoreCase(str, DRIVE_FOLDER_MIME)) return .folder;
        if (std.ascii.findIgnoreCase(str, "image/") != null) return .image;
        return null;
    }
};

fn getDriveFiles(
    a: Allocator,
    client: *std.http.Client,
    auth_header: std.http.Client.Request.Headers.Value,
) anyerror![]DriveFile {
    var all_files = try std.ArrayList(DriveFile).initCapacity(a, 64);
    var page_token: ?[]u8 = null;

    while (true) {
        const uri_str = if (page_token) |token|
            try std.fmt.allocPrint(
                a,
                "https://www.googleapis.com/drive/v3/files?fields=files(id,name,mimeType,modifiedTime,parents)&pageToken={s}",
                .{token},
            )
        else
            try std.fmt.allocPrint(
                a,
                "https://www.googleapis.com/drive/v3/files?fields=files(id,name,mimeType,modifiedTime,parents),nextPageToken",
                .{},
            );
        defer a.free(uri_str);

        const uri = try std.Uri.parse(uri_str);
        const headers = std.http.Client.Request.Headers{
            .authorization = auth_header,
            .accept_encoding = .{ .override = "identity" },
        };

        var req = try client.request(.GET, uri, .{
            .headers = headers,
            .redirect_behavior = .not_allowed,
            .keep_alive = false,
        });
        defer req.deinit();

        try req.sendBodiless();

        var res = try req.receiveHead(&.{});

        const response_transfer_buffer = try a.alloc(u8, 1024 * 1024);
        defer a.free(response_transfer_buffer);

        const body_reader = res.reader(response_transfer_buffer);
        const res_body = try body_reader.allocRemaining(a, .unlimited);
        defer a.free(res_body);
        log.debug(
            \\ Res body: {s}
        , .{res_body});
        const status = res.head.status.class();
        var parsed: ?std.json.Parsed(DriveResponse) = null;

        if (status == std.http.Status.Class.success) {
            parsed = try std.json.parseFromSlice(
                DriveResponse,
                a,
                res_body,
                .{
                    .ignore_unknown_fields = true,
                },
            );
        }

        if (parsed) |json| {
            defer json.deinit();

            for (json.value.files) |f| {
                try all_files.append(a, .{
                    .id = try a.dupe(u8, f.id),
                    .name = try a.dupe(u8, f.name),
                    .mimeType = try a.dupe(u8, f.mimeType),
                    .modifiedTime = try a.dupe(u8, f.modifiedTime),
                    .parents = if (f.parents) |p| blk: {
                        const duped = try a.alloc([]u8, p.len);
                        for (duped, p) |*d, s| d.* = try a.dupe(u8, s);
                        break :blk duped;
                    } else null,
                });
            }

            if (json.value.nextPageToken) |token| {
                if (page_token) |old| a.free(old);
                page_token = try a.dupe(u8, token);
            } else {
                if (page_token) |old| a.free(old);
                break;
            }
        } else {
            log.err(
                \\Error fetching folder at '{s}'
                \\status: {s}
                \\body: {s}
            , .{ uri_str, @tagName(status), res_body });
            return error.StatusNotSuccess;
        }
    }
    return all_files.toOwnedSlice(a);
}

fn sortFolderFilesByMime(a: Allocator, folder_files: std.json.Parsed(DriveResponse)) Allocator.Error!std.array_hash_map.Auto(MimeOption, []DriveFile) {
    var docs = std.ArrayList(DriveFile).empty;
    var folders = std.ArrayList(DriveFile).empty;
    var images = std.ArrayList(DriveFile).empty;

    for (folder_files.value.files) |file| {
        const mime = MimeOption.tryFromStr(file.mimeType) orelse {
            log.warn(
                \\ encountered unexpected mime: {s}
            , .{file.mimeType});
            continue;
        };

        switch (mime) {
            .doc => try docs.append(a, file),
            .folder => try folders.append(a, file),
            .image => try images.append(a, file),
        }
    }

    return try std.array_hash_map.Auto(MimeOption, []DriveFile).init(
        a,
        &.{ .doc, .folder, .image },
        &.{
            try docs.toOwnedSlice(a),
            try folders.toOwnedSlice(a),
            try images.toOwnedSlice(a),
        },
    );
}

fn downloadImageFile(
    a: Allocator,
    io: std.Io,
    client: *std.http.Client,
    auth_header: std.http.Client.Request.Headers.Value,
    file_handle: root.FileHandle,
) !void {
    // const output_path = try std.fmt.allocPrint(
    //     a,
    //     root.DRIVE_DIR ++ "{s}",
    //     .{file_handle.filepath},
    // );
    // defer a.free(output_path);

    const cwd = std.Io.Dir.cwd();
    // Skip existing files.
    cwd.access(io, file_handle.filepath, .{}) catch {
        const last_backslash = std.mem.findScalarLast(u8, file_handle.filepath, '/') orelse {
            log.err(
                \\ filepath '{s}' has no backslash?
            , .{file_handle.filepath});
            return error.InvalidPath;
        };

        const dir_path = file_handle.filepath[0..last_backslash];
        log.warn(
            \\ dirpath for '{s}': {s}
        , .{ file_handle.filepath, dir_path });

        try cwd.createDirPath(io, dir_path);

        const uri_str = try std.fmt.allocPrint(
            a,
            "https://www.googleapis.com/drive/v3/files/{s}?alt=media",
            .{file_handle.id},
        );
        defer a.free(uri_str);

        const uri = try std.Uri.parse(uri_str);

        const headers = std.http.Client.Request.Headers{
            .authorization = auth_header,
            .accept_encoding = .{ .override = "identity" },
        };

        var req = try client.request(.GET, uri, .{
            .headers = headers,
            .redirect_behavior = .not_allowed,
            .keep_alive = true,
        });
        defer req.deinit();

        log.info(
            \\downloading: {s} 
        , .{file_handle.filepath});
        try req.sendBodiless();

        var res = try req.receiveHead(&.{});

        const transfer_buffer = try a.alloc(u8, 1024 * 1024);
        defer a.free(transfer_buffer);

        const reader = res.reader(transfer_buffer);
        const body = try reader.allocRemaining(a, .unlimited);
        defer a.free(body);

        if (res.head.status.class() != .success) {
            std.log.err(
                "failed downloading {s}: {s}",
                .{ file_handle.filepath, body },
            );
            return error.DownloadFailed;
        }

        var out = cwd.createFile(io, file_handle.filepath, .{}) catch |err| {
            log.err(
                \\ Error creating image file '{s}': {s}
            , .{ file_handle.filepath, @errorName(err) });
            return err;
        };
        defer out.close(io);

        try out.writeStreamingAll(io, body);

        log.info("downloaded {s}", .{file_handle.filepath});
    };
}

fn downloadDoc(
    a: Allocator,
    io: std.Io,
    client: *std.http.Client,
    auth_header: std.http.Client.Request.Headers.Value,
    file_handle: root.FileHandle,
) ![]u8 {
    // const output_path = try std.fmt.allocPrint(
    //     a,
    //     root.DRIVE_DIR ++ "{s}",
    //     .{file_handle.filepath},
    // );
    // defer a.free(output_path);

    const cwd = std.Io.Dir.cwd();
    // Skip existing files.
    cwd.access(io, file_handle.filepath, .{}) catch {
        const last_backslash = std.mem.findScalarLast(u8, file_handle.filepath, '/') orelse {
            log.err(
                \\ filepath '{s}' has no backslash?
            , .{file_handle.filepath});
            return error.InvalidPath;
        };

        const dir_path = file_handle.filepath[0..last_backslash];
        try cwd.createDirPath(io, dir_path);

        const uri_str = try std.fmt.allocPrint(
            a,
            "https://www.googleapis.com/drive/v3/files/{s}/export?mimeType=text/plain",
            .{file_handle.id},
        );

        log.debug(
            \\downloadDoc url: {s}
        , .{uri_str});
        defer a.free(uri_str);

        const uri = try std.Uri.parse(uri_str);

        const headers = std.http.Client.Request.Headers{
            .authorization = auth_header,
            .accept_encoding = .{ .override = "identity" },
        };

        var req = try client.request(.GET, uri, .{
            .headers = headers,
            .redirect_behavior = .not_allowed,
            .keep_alive = true,
        });
        defer req.deinit();

        log.info(
            \\downloading: {s} 
        , .{file_handle.filepath});
        try req.sendBodiless();

        var res = try req.receiveHead(&.{});

        const transfer_buffer = try a.alloc(u8, 1024 * 1024);
        defer a.free(transfer_buffer);

        const reader = res.reader(transfer_buffer);
        const body = try reader.allocRemaining(a, .unlimited);

        if (res.head.status.class() != .success) {
            std.log.err(
                "failed downloading {s}: {s}",
                .{ file_handle.filepath, body },
            );
            return error.DownloadFailed;
        }

        var out = cwd.createFile(io, file_handle.filepath, .{}) catch |err| {
            log.err(
                \\ Error creating file '{s}': {s}
            , .{ file_handle.filepath, @errorName(err) });
            return err;
        };
        defer out.close(io);

        try out.writeStreamingAll(io, body);

        log.info("downloaded {s}", .{file_handle.filepath});
        return body;
    };

    const file = try std.Io.Dir.cwd().openFile(io, file_handle.filepath, .{});
    defer file.close(io);
    const transfer_buffer = try a.alloc(u8, 1024 * 1024);
    defer a.free(transfer_buffer);
    var reader = file.reader(io, transfer_buffer);

    return try reader.interface.allocRemaining(a, .unlimited);
}
