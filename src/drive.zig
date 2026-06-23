const std = @import("std");
const zemplate = @import("zemplate");
const zyph = @import("zyph");
const dotenv = @import("dotenv");
const print = std.debug.print;
const log = std.log.scoped(.drive);
const Request = std.http.Server.Request;

const DriveFile = struct {
    kind: []u8,
    mimeType: []u8,
    id: []u8,
    name: []u8,
};

const DriveResponse = struct {
    files: []DriveFile,

    pub fn format(self: *const DriveResponse, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.files) |f| {
            try w.print(
                \\ name: {s}
                \\ id: {s}
                \\ kind: {s}
                \\ mimeType: {s}
            , .{ f.name, f.id, f.kind, f.mimeType });
        }
    }
};

pub const ImageCategory = enum {
    unpub_illustration,
    sketch,
    editorial,
    portraits,
};

const DRIVE_FOLDER_MIME = "application/vnd.google-apps.folder";
const DRIVE_DOC_MIME = "application/vnd.google-apps.document";
const MimeOption = enum {
    folder,
    image,
    doc,
    fn uriStr(self: @This()) []const u8 {
        return switch (self) {
            .folder => "+and+mimeType='" ++ DRIVE_FOLDER_MIME ++ "'",
            .doc => "+and+mimeType='" ++ DRIVE_DOC_MIME ++ "'",
            .image => "+and+mimeType+contains+'image/'",
        };
    }
};
fn getFolderFilesMatchingMime(
    a: std.mem.Allocator,
    client: *std.http.Client,
    auth_header: std.http.Client.Request.Headers.Value,
    folder_id: []const u8,
    mime: MimeOption,
) anyerror!std.json.Parsed(DriveResponse) {
    const uri_str = try std.fmt.allocPrint(a,
        \\https://www.googleapis.com/drive/v3/files?q='{s}'+in+parents{s}&fields=files(id,name,mimeType,kind)
    , .{ folder_id, mime.uriStr() });
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
    const status = res.head.status.class();
    if (status == std.http.Status.Class.success) {
        return try std.json.parseFromSlice(
            DriveResponse,
            a,
            res_body,
            .{
                .ignore_unknown_fields = true,
            },
        );
    }

    log.err(
        \\Error fetching folder at '{s}'
        \\status: {s}
        \\body: {s}
    , .{ uri_str, @tagName(status), res_body });
    return error.StatusNotSuccess;
}

pub const FileHandle = struct {
    id: []u8,
    filepath: []u8,
};

const FilesTable = struct {
    const Entry = struct {
        files: std.ArrayList(FolderFiles) = .empty,
        template: ?FileHandle = null,
    };

    unpub_illustration: Entry = .{},
    sketch: Entry = .{},
    editorial: Entry = .{},
    portraits: Entry = .{},

    fn getField(
        self: *@This(),
        category: ImageCategory,
    ) *Entry {
        return &switch (category) {
            .unpub_illustration => self.unpub_illustration,
            .sketch => self.sketch,
            .editorial => self.editorial,
            .portraits => self.portraits,
        };
    }

    pub fn deinit(self: *@This(), a: std.mem.Allocator) void {
        for (std.meta.tags(ImageCategory)) |category| {
            self.getField(category).files.deinit(a);
        }
    }
};

/// This struct should not be deinitialized
/// Instead, ownership of image_files is passed to CategoryData
const FolderFiles = struct {
    handle: FileHandle,
    image_files: []FileHandle,
    template: ?FileHandle,
};

fn collectFilesRecursive(
    a: std.mem.Allocator,
    folder_id: []const u8,
    folder_name: []const u8,
    table_entry: *FilesTable.Entry,
    client: *std.http.Client,
    authorization_header: std.http.Client.Request.Headers.Value,
) anyerror!void {
    log.debug(
        \\ fetching image files from folder {s}
    , .{folder_name});
    const image_files = try getFolderFilesMatchingMime(a, client, authorization_header, folder_id, .image);
    defer image_files.deinit();
    log.debug(
        \\ fetching text files from folder {s}
    , .{folder_name});
    const docs = try getFolderFilesMatchingMime(a, client, authorization_header, folder_id, .doc);
    defer docs.deinit();

    const image_file_handles = try a.alloc(FileHandle, image_files.value.files.len);

    for (image_files.value.files, 0..) |file, i| {
        image_file_handles[i] = .{
            .id = try a.dupe(u8, file.id),
            .filepath = try std.fmt.allocPrint(a, "{s}/{s}", .{ folder_name, file.name }),
        };
    }

    var template: ?FileHandle = null;
    for (docs.value.files) |doc_file| {
        if (std.ascii.findIgnoreCase(doc_file.name, "template")) |_| {
            template = .{
                .id = try a.dupe(u8, doc_file.id),
                .filepath = try std.fmt.allocPrint(a, "{s}/{s}", .{ folder_name, doc_file.name }),
            };
            break;
        }

        log.err(
            \\ Encountered unexpected text file: '{s}'
        , .{doc_file.name});
    }

    const folder_files = FolderFiles{
        .handle = .{
            .id = try a.dupe(u8, folder_id),
            .filepath = try a.dupe(u8, folder_name),
        },
        .image_files = image_file_handles,
        .template = template,
    };
    try table_entry.files.append(a, folder_files);

    log.debug(
        \\ fetching folder files from folder {s}
    , .{folder_name});
    const inner_folders = try getFolderFilesMatchingMime(a, client, authorization_header, folder_id, .folder);
    defer inner_folders.deinit();

    if (inner_folders.value.files.len != 0) {
        if (template) |templ|
            table_entry.template = templ;
    }

    for (inner_folders.value.files) |file|
        try collectFilesRecursive(a, file.id, file.name, table_entry, client, authorization_header);
}

fn getFilesTable(
    a: std.mem.Allocator,
    folder_id: []const u8,
    client: *std.http.Client,
    authorization_header: std.http.Client.Request.Headers.Value,
) anyerror!FilesTable {
    const parsed = try getFolderFilesMatchingMime(
        a,
        client,
        authorization_header,
        folder_id,
        .folder,
    );
    defer parsed.deinit();
    log.debug(
        \\ parsed folder {f}
    , .{parsed.value});
    for (parsed.value.files) |f| {
        log.debug(
            \\ checking {s}
        , .{f.name});
    }

    var files_table = FilesTable{};
    // const files_table = FilesTable{};
    var all_tags = std.StringHashMapUnmanaged(ImageCategory){};
    for (std.meta.tags(ImageCategory)) |category|
        try all_tags.put(a, @tagName(category), category);

    for (parsed.value.files) |f| {
        if (all_tags.get(f.name)) |cat| {
            log.debug(
                \\ collecting from {s}
            , .{f.name});
            try collectFilesRecursive(a, f.id, f.name, files_table.getField(cat), client, authorization_header);
        }
    }

    return files_table;
}

/// Runs a bash script to get access token
/// make sure to free authorization_header.override
pub fn createClientAndAuthHeader(a: std.mem.Allocator, io: std.Io) anyerror!struct { std.http.Client, std.http.Client.Request.Headers.Value } {
    const result = try std.process.spawn(io, .{
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

const SyncContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    client: std.http.Client,
    auth_header: std.http.Client.Request.Headers.Value,

    collections: []ImageCollection,
};

const WorkItem = struct {
    category: []const u8,
    file: DriveFile,
};

const DRIVE_FOLDER = "serve/drive/";

fn downloadImageFile(
    a: std.mem.Allocator,
    io: std.Io,
    client: *std.http.Client,
    auth_header: std.http.Client.Request.Headers.Value,
    file_handle: FileHandle,
) !void {
    const output_path = try std.fmt.allocPrint(
        a,
        DRIVE_FOLDER ++ "{s}",
        .{file_handle.filepath},
    );
    defer a.free(output_path);

    const cwd = std.Io.Dir.cwd();
    // Skip existing files.
    cwd.access(io, output_path, .{}) catch {
        var parent_dir = std.mem.splitScalar(u8, file_handle.filepath, '/');
        const dir_path = try std.fmt.allocPrint(
            a,
            DRIVE_FOLDER ++ "{s}",
            .{parent_dir.first()},
        );
        defer a.free(dir_path);

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

        var out = try cwd.createFile(io, output_path, .{});
        defer out.close(io);

        try out.writeStreamingAll(io, body);

        log.info("downloaded {s}", .{output_path});
    };
}

fn downloadDoc(
    a: std.mem.Allocator,
    io: std.Io,
    client: *std.http.Client,
    auth_header: std.http.Client.Request.Headers.Value,
    file_handle: FileHandle,
) ![]u8 {
    const output_path = try std.fmt.allocPrint(
        a,
        DRIVE_FOLDER ++ "{s}",
        .{file_handle.filepath},
    );
    defer a.free(output_path);

    const cwd = std.Io.Dir.cwd();
    // Skip existing files.
    cwd.access(io, output_path, .{}) catch {
        var parent_dir = std.mem.splitScalar(u8, file_handle.filepath, '/');
        const dir_path = try std.fmt.allocPrint(
            a,
            DRIVE_FOLDER ++ "{s}",
            .{parent_dir.first()},
        );
        defer a.free(dir_path);

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

        var out = try cwd.createFile(io, output_path, .{});
        defer out.close(io);

        try out.writeStreamingAll(io, body);

        log.info("downloaded {s}", .{output_path});
        return body;
    };

    const file = try std.Io.Dir.cwd().openFile(io, output_path, .{});
    defer file.close(io);
    const transfer_buffer = try a.alloc(u8, 1024 * 1024);
    defer a.free(transfer_buffer);
    var reader = file.reader(io, transfer_buffer);

    return try reader.interface.allocRemaining(a, .unlimited);
}

fn imageSyncWorker(ctx: *SyncContext) !void {
    defer ctx.client.deinit();
    defer ctx.allocator.destroy(ctx);
    for (ctx.collections) |coll| {
        for (coll.image_files) |img| {
            try downloadImageFile(
                ctx.allocator,
                ctx.io,
                &ctx.client,
                ctx.auth_header,
                img,
            );
        }
    }
}

pub const PageZemplate = struct {
    const ImageItem = struct { file: FileHandle, text: ?[]const u8 };
    const Collection = struct {
        image_items: []const ImageItem,
        template: ?ImageCollection.Template,
    };

    collections: []Collection,
};

pub const ImageCollection = struct {
    const Template = struct {
        info: Info,
        order: ?[]OrderEntry = null,
        const SEPARATOR = "-\n";

        fn deinit(self: *@This(), a: std.mem.Allocator) void {
            if (self.order) |order| a.free(order);
        }

        /// parses for Template with fallback info
        /// fallback will overwrite any null info fields
        fn parse(
            a: std.mem.Allocator,
            text: []const u8,
            info_fallback: Info,
        ) !@This() {
            const sep_idx = std.ascii.findIgnoreCase(text, SEPARATOR) orelse text.len;

            var info = parseInfo(a, text[0..sep_idx]);

            if (info_fallback.title) |title| {
                if (info.title == null) info.title = title;
            }
            if (info_fallback.body) |body| {
                if (info.body == null) info.body = body;
            }

            return .{
                .info = info,
                .order = if (sep_idx != text.len) try parseOrder(a, text[sep_idx + SEPARATOR.len ..]) else null,
            };
        }
    };

    handle: FileHandle,
    image_files: []FileHandle,
    template: ?Template,

    pub fn deinit(self: *@This(), a: std.mem.Allocator) void {
        a.free(self.handle.id);
        a.free(self.handle.filepath);

        for (self.image_files) |f| {
            a.free(f.id);
            a.free(f.filepath);
        }
        a.free(self.image_files);
        if (self.template) |t| t.deinit(a);
    }
};

pub const CategoryData = struct {
    const Entry = struct {
        collections: []ImageCollection = undefined,
        template: ?ImageCollection.Template = null,
    };

    unpub_illustration: Entry = .{},
    sketch: Entry = .{},
    editorial: Entry = .{},
    portraits: Entry = .{},

    fn getField(
        self: *@This(),
        category: ImageCategory,
    ) *Entry {
        return &switch (category) {
            .unpub_illustration => self.unpub_illustration,
            .sketch => self.sketch,
            .editorial => self.editorial,
            .portraits => self.portraits,
        };
    }

    fn getFieldConst(
        self: *const @This(),
        category: ImageCategory,
    ) *const Entry {
        return &switch (category) {
            .unpub_illustration => self.unpub_illustration,
            .sketch => self.sketch,
            .editorial => self.editorial,
            .portraits => self.portraits,
        };
    }

    pub fn deinit(self: *@This(), a: std.mem.Allocator) void {
        for (std.meta.tags(ImageCategory)) |category| {
            a.free(self.getField(category).collections);
            if (self.getField(category).template) |*tmp| tmp.deinit(a);
        }
    }

    pub fn build(
        a: std.mem.Allocator,
        io: std.Io,
        client: *std.http.Client,
        auth_header: std.http.Client.Request.Headers.Value,
        outermost_folder_id: []const u8,
    ) !@This() {
        var files_table = try getFilesTable(
            a,
            outermost_folder_id,
            client,
            auth_header,
        );
        defer files_table.deinit(a);
        log.debug(
            \\ created full files table
        , .{});
        var self = @This(){};

        // should create diff against file system
        // then disatch threads to download
        // then update the file system

        for (std.meta.tags(ImageCategory)) |category| {
            if (files_table.getField(category).template) |template| {
                const raw = try downloadDoc(a, io, client, auth_header, template);
                defer a.free(raw);

                self.getField(category).template = try ImageCollection.Template.parse(a, raw, .{
                    .title = a.dupe(u8, @tagName(category)) catch @panic("OOM"),
                });
            }

            log.debug(
                \\Downloading collections for category '{s}'
            , .{@tagName(category)});
            var collections = std.ArrayList(ImageCollection).empty;
            for (files_table.getField(category).files.items) |*files| {
                const template = blk: {
                    const tmp = files.template orelse break :blk null;
                    const doc_txt = try downloadDoc(a, io, client, auth_header, tmp);
                    defer a.free(doc_txt);
                    break :blk try ImageCollection.Template.parse(a, doc_txt, .{
                        .title = files.handle.filepath,
                    });
                };

                log.debug(
                    \\Adding collection for '{s}'
                , .{files.handle.filepath});
                try collections.append(a, .{
                    .handle = files.handle,
                    .template = template,
                    .image_files = files.image_files,
                });
            }
            self.getField(category).collections = try collections.toOwnedSlice(a);
        }

        return self;
    }

    pub fn syncImages(
        self: *const @This(),
        allocator: std.mem.Allocator,
        io: std.Io,
        auth_header: std.http.Client.Request.Headers.Value,
    ) anyerror!void {
        const threads = try allocator.alloc(std.Thread, std.meta.tags(ImageCategory).len);
        defer allocator.free(threads);

        var threaded = std.Io.Threaded.init(allocator, .{});
        for (threads, std.meta.tags(ImageCategory)) |*thread, category| {
            const ctx = try allocator.create(SyncContext);
            const image_collections = self.getFieldConst(category).collections;

            const client = std.http.Client{
                .allocator = allocator,
                .io = io,
                // must be explicitly set to avoid an indefinte hang
                .write_buffer_size = 1024 * 32,
            };

            ctx.* = .{
                .allocator = allocator,
                .io = threaded.io(),
                .client = client,
                .auth_header = auth_header,
                .collections = image_collections,
            };
            thread.* = try std.Thread.spawn(
                .{},
                imageSyncWorker,
                .{ctx},
            );
        }

        for (threads) |thread| {
            thread.join();
        }
    }

    pub fn createOrderedTemplates(
        self: *const @This(),
        a: std.mem.Allocator,
    ) !std.StringHashMapUnmanaged(PageZemplate) {
        var templates = std.StringHashMapUnmanaged(PageZemplate){};

        for (std.meta.tags(ImageCategory)) |category| {
            var all_collections = std.ArrayList(PageZemplate.Collection).empty;

            for (self.getFieldConst(category).collections) |coll| {
                const ordered: []PageZemplate.ImageItem = if (coll.template != null and coll.template.?.order != null) blk: {
                    const order = coll.template.?.order.?;
                    var result = try std.ArrayList(PageZemplate.ImageItem).initCapacity(a, order.len);
                    for (order) |o_entry| {
                        const matched = for (coll.image_files) |fh| {
                            const stem = if (std.mem.lastIndexOfScalar(u8, fh.filepath, '/')) |slash|
                                fh.filepath[slash + 1 ..]
                            else
                                fh.filepath;
                            const bare = if (std.mem.lastIndexOfScalar(u8, stem, '.')) |dot|
                                stem[0..dot]
                            else
                                stem;
                            if (std.ascii.eqlIgnoreCase(bare, o_entry.filename)) break fh;
                        } else {
                            log.debug("order entry '{s}' has no matching image, skipping", .{o_entry.filename});
                            continue;
                        };
                        try result.append(a, .{
                            .file = matched,
                            .text = o_entry.text,
                        });
                    }
                    break :blk try result.toOwnedSlice(a);
                } else unordered: {
                    var result = try std.ArrayList(PageZemplate.ImageItem).initCapacity(a, coll.image_files.len);
                    for (coll.image_files) |fh|
                        try result.append(a, .{ .file = fh, .text = null });
                    break :unordered try result.toOwnedSlice(a);
                };

                try all_collections.append(a, .{
                    .image_items = ordered,
                    .template = coll.template,
                });
            }

            try templates.put(a, @tagName(category), .{
                .collections = try all_collections.toOwnedSlice(a),
            });
        }

        return templates;
    }
};

pub const Info = struct {
    title: ?[]u8,
    body: ?[]u8 = null,
    pub fn deinit(self: *Info, a: std.mem.Allocator) void {
        if (self.title) |title| a.free(title);
        if (self.body) |body| a.free(body);
    }
};

pub fn parseInfo(a: std.mem.Allocator, input: []const u8) Info {
    const title_prefix = "title:";
    const body_prefix = "body:";

    const title = title: {
        var lines = std.mem.splitScalar(u8, input, '\n');

        var title_line = lines.next() orelse break :title null;
        title_line = std.mem.trimStart(u8, title_line, " \n\t");

        if (!std.ascii.startsWithIgnoreCase(title_line, title_prefix)) break :title null;

        break :title std.mem.trim(
            u8,
            title_line[title_prefix.len..],
            " \t",
        );
    } orelse null;

    const body = body: {
        var lines = std.mem.splitScalar(u8, input, '\n');

        var body_line = lines.next() orelse break :body null;
        body_line = std.mem.trimStart(u8, body_line, " \n\t");

        if (!std.ascii.startsWithIgnoreCase(body_line, body_prefix)) break :body null;

        break :body std.mem.trim(
            u8,
            body_line[body_prefix.len..],
            " \t",
        );
    } orelse null;

    return .{
        .title = if (title) |t| a.dupe(u8, t) catch @panic("OOM") else null,
        .body = if (body) |b| a.dupe(u8, b) catch @panic("OOM") else null,
    };
}

pub const OrderEntry = struct {
    filename: []u8,
    text: ?[]u8,

    pub fn deinit(self: *OrderEntry, a: std.mem.Allocator) void {
        a.free(self.filename);
        if (self.text) |text| a.free(text);
    }
};

pub fn parseOrder(
    a: std.mem.Allocator,
    input: []const u8,
) ![]OrderEntry {
    var lines = std.mem.splitScalar(u8, input, '\n');

    var list = try std.ArrayList(OrderEntry).initCapacity(a, 16);
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0) continue;

        var split = std.mem.splitScalar(u8, line, '-');
        const split_first = split.first();
        if (split.peek() != null) {
            try list.append(a, OrderEntry{
                .filename = try a.dupe(u8, std.mem.trim(u8, split_first, " \t")),
                .text = try a.dupe(u8, std.mem.trim(u8, split.rest(), " \t")),
            });
        } else try list.append(a, OrderEntry{
            .filename = try a.dupe(u8, line),
            .text = null,
        });
    }

    return try list.toOwnedSlice(a);
}

test "parseOrder" {
    const Expected = struct {
        filename: []const u8,
        text: ?[]const u8,
    };

    const input =
        \\StBenedict - Saint Benedict
        \\Ezra - Ezra
        \\VeryLong - Many words are in this entry. Even some punctuation! and what else? commas! ,,, and hyphens --- 
        \\OtherPerson -Other Person
        \\OtherPerson2-Some! Other Person
        \\ThisOneHasNoText
    ;

    const expected = [_]Expected{
        .{ .filename = "StBenedict", .text = "Saint Benedict" },
        .{ .filename = "Ezra", .text = "Ezra" },
        .{ .filename = "VeryLong", .text = "Many words are in this entry. Even some punctuation! and what else? commas! ,,, and hyphens ---" },
        .{ .filename = "OtherPerson", .text = "Other Person" },
        .{ .filename = "OtherPerson2", .text = "Some! Other Person" },
        .{ .filename = "ThisOneHasNoText", .text = null },
    };

    const list = try parseOrder(
        std.testing.allocator,
        input,
    );
    defer std.testing.allocator.free(list);
    for (expected, list) |exp, entry| {
        try std.testing.expectEqualStrings(
            exp.filename,
            entry.filename,
        );
        if (exp.text) |text| {
            try std.testing.expectEqualStrings(
                text,
                entry.text.?,
            );
        } else try std.testing.expectEqual(entry.text, null);
    }

    std.debug.print(
        \\Test success!
        \\
    , .{});
}

test "parseInfo" {
    const input =
        \\title: Title!
        \\body: Body text
        \\is long
        \\and multiple lines
    ;

    const info = try parseInfo(input);

    try std.testing.expectEqualStrings(
        "Title!",
        info.title,
    );

    try std.testing.expectEqualStrings(
        \\Body text
        \\is long
        \\and multiple lines
    ,
        info.body,
    );

    std.debug.print(
        \\Test success!
        \\
    , .{});
}
