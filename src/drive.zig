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
};

pub const ImageCategory = enum {
    picture_book,
    sketch,
    editorial,
    portraits,
};

const DRIVE_FOLDER_MIME = "application/vnd.google-apps.folder";
const MimeOption = enum { folder, image, text };

fn getFilesMap(
    a: std.mem.Allocator,
    folder_id: []const u8,
    client: *std.http.Client,
    authorization_header: std.http.Client.Request.Headers.Value,
) anyerror!FilesMap {
    const parsed = try getFolderFilesMatchingMime(
        a,
        client,
        authorization_header,
        folder_id,
        .folder,
    );
    defer parsed.deinit();

    var files_map = FilesMap{};

    inline for ([_]ImageCategory{ .editorial, .picture_book, .portraits, .sketch }) |category| {
        const category_str = @tagName(category);
        for (parsed.value.files) |f| {
            if (std.mem.eql(u8, f.name, category_str)) {
                std.debug.print("found {s}: {s}\n", .{ category_str, f.id });

                const image_files = try getFolderFilesMatchingMime(a, client, authorization_header, f.id, .image);
                defer image_files.deinit();
                const text_files = try getFolderFilesMatchingMime(a, client, authorization_header, f.id, .text);
                defer text_files.deinit();

                const image_file_handles = try a.alloc(FileHandle, image_files.value.files.len);

                for (image_files.value.files, 0..) |file, i| {
                    image_file_handles[i] = .{
                        .id = try a.dupe(u8, file.id),
                        .filepath = try std.fmt.allocPrint(a, "{s}/{s}", .{ category_str, file.name }),
                    };
                }

                var info: ?FileHandle = null;
                var order: ?FileHandle = null;
                for (text_files.value.files) |text_file| {
                    const lowername = try std.ascii.allocLowerString(a, text_file.name);
                    defer a.free(lowername);

                    if (std.mem.containsAtLeast(u8, lowername, 1, "order")) {
                        order = .{
                            .id = try a.dupe(u8, text_file.id),
                            .filepath = try std.fmt.allocPrint(a, "{s}/{s}", .{ category_str, text_file.name }),
                        };
                    } else if (std.mem.containsAtLeast(u8, lowername, 1, "info")) {
                        info = .{
                            .id = try a.dupe(u8, text_file.id),
                            .filepath = try std.fmt.allocPrint(a, "{s}/{s}", .{ category_str, text_file.name }),
                        };
                    } else {
                        log.err(
                            \\ Encountered unexpected text file: '{s}'
                        , .{text_file.name});
                    }
                }

                const folder_files = FolderFiles{
                    .image_files = image_file_handles,
                    .info = info,
                    .order = order,
                };
                try files_map.put(a, category_str, folder_files);
            }
        }
    }

    return files_map;
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
    log.warn("Access Token: {s}", .{access_token});

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
    client: *std.http.Client,
    auth_header: std.http.Client.Request.Headers.Value,

    category: ImageCategory,
    files: []FileHandle,
};

const WorkItem = struct {
    category: []const u8,
    file: DriveFile,
};

fn downloadImageFile(
    a: std.mem.Allocator,
    io: std.Io,
    client: *std.http.Client,
    auth_header: std.http.Client.Request.Headers.Value,
    file_handle: FileHandle,
) !void {
    const output_path = try std.fmt.allocPrint(
        a,
        "serve/imgs/{s}",
        .{file_handle.filepath},
    );
    defer a.free(output_path);

    const cwd = std.Io.Dir.cwd();
    // Skip existing files.
    cwd.access(io, output_path, .{}) catch {
        var parent_dir = std.mem.splitScalar(u8, file_handle.filepath, '/');
        const dir_path = try std.fmt.allocPrint(
            a,
            "serve/imgs/{s}",
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
            .keep_alive = false,
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

fn fetchTextContent(
    a: std.mem.Allocator,
    client: *std.http.Client,
    auth_header: std.http.Client.Request.Headers.Value,
    file_handle: FileHandle,
) ![]u8 {
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
        .keep_alive = false,
    });
    defer req.deinit();

    log.info(
        \\fetching: {s} 
    , .{file_handle.filepath});
    try req.sendBodiless();

    var res = try req.receiveHead(&.{});

    const transfer_buffer = try a.alloc(u8, 1024 * 1024);
    defer a.free(transfer_buffer);

    const reader = res.reader(transfer_buffer);
    const body = try reader.allocRemaining(a, .unlimited);
    return body;
}

fn imageSyncWorker(ctx: *SyncContext) !void {
    defer ctx.allocator.destroy(ctx);
    for (ctx.files) |file| {
        try downloadImageFile(
            ctx.allocator,
            ctx.io,
            ctx.client,
            ctx.auth_header,
            file,
        );
    }
}

fn getFolderFilesMatchingMime(
    a: std.mem.Allocator,
    client: *std.http.Client,
    auth_header: std.http.Client.Request.Headers.Value,
    folder_id: []const u8,
    mime: MimeOption,
) anyerror!std.json.Parsed(DriveResponse) {
    const mime_str = try switch (mime) {
        .folder => std.fmt.allocPrint(a, "+and+mimeType='{s}'", .{DRIVE_FOLDER_MIME}),
        .image => std.fmt.allocPrint(a, "+and+mimeType+contains+'image/'", .{}),
        .text => std.fmt.allocPrint(a, "+and+mimeType='text/plain'", .{}),
    };
    defer a.free(mime_str);

    const uri_str = try std.fmt.allocPrint(a,
        \\https://www.googleapis.com/drive/v3/files?q='{s}'+in+parents{s}&fields=files(id,name,mimeType,kind)
    , .{ folder_id, mime_str });
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

const FilesMap = std.StringHashMapUnmanaged(FolderFiles);
/// This struct should not be deinitialized
/// Instead, ownership of image_files is passed to CategoryData
const FolderFiles = struct {
    image_files: []FileHandle,
    info: ?FileHandle,
    order: ?FileHandle,
};

const ImageItem = struct { file: FileHandle, text: ?[]const u8 };

pub const CategoryPageTemplate = struct {
    image_items: []const ImageItem,
    info: ?Info,
};

pub const CategoryData = struct {
    image_files: []FileHandle,
    info: ?Info,
    order: ?[]OrderEntry,

    pub const Map = std.StringHashMapUnmanaged(CategoryData);

    pub fn deinit(self: *@This(), a: std.mem.Allocator) void {
        for (self.image_files) |f| {
            a.free(f.id);
            a.free(f.filepath);
        }
        a.free(self.image_files);
        if (self.order) |order| a.free(order);
    }

    pub fn buildMap(
        a: std.mem.Allocator,
        client: *std.http.Client,
        auth_header: std.http.Client.Request.Headers.Value,
        outermost_folder_id: []const u8,
    ) !Map {
        var files_map = try getFilesMap(
            a,
            outermost_folder_id,
            client,
            auth_header,
        );
        defer files_map.deinit(a);

        var result = std.StringHashMapUnmanaged(CategoryData){};

        var iter = files_map.iterator();
        while (iter.next()) |entry| {
            const folder_files = entry.value_ptr;

            var info: ?Info = null;
            var order: ?[]OrderEntry = null;

            if (folder_files.info) |handle| {
                const raw = try fetchTextContent(a, client, auth_header, handle);
                defer a.free(raw);
                info = try parseInfo(raw);
            }

            if (folder_files.order) |handle| {
                const raw = try fetchTextContent(a, client, auth_header, handle);
                defer a.free(raw);
                order = try parseOrder(a, raw);
            }

            try result.put(a, entry.key_ptr.*, .{
                .info = info,
                .order = order,
                .image_files = folder_files.image_files,
            });
        }

        return result;
    }

    pub fn syncImages(
        allocator: std.mem.Allocator,
        io: std.Io,
        client: *std.http.Client,
        auth_header: std.http.Client.Request.Headers.Value,
        category_map: *const Map,
    ) anyerror!void {
        const threads = try allocator.alloc(std.Thread, std.meta.tags(ImageCategory).len);
        defer allocator.free(threads);

        for (threads, std.meta.tags(ImageCategory)) |*thread, category| {
            const ctx = try allocator.create(SyncContext);

            ctx.* = .{
                .allocator = allocator,
                .io = io,
                .client = client,
                .auth_header = auth_header,
                .files = category_map.get(@tagName(category)).?.image_files,
                .category = category,
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
        a: std.mem.Allocator,
        map: *const Map,
    ) !std.StringHashMapUnmanaged(CategoryPageTemplate) {
        var templates = std.StringHashMapUnmanaged(CategoryPageTemplate){};

        var iter = map.iterator();
        while (iter.next()) |entry| {
            const cat = entry.key_ptr;
            const category_data = entry.value_ptr;
            const image_files = category_data.image_files;
            const ordered: []ImageItem = if (category_data.order) |order| blk: {
                var result = try std.ArrayList(ImageItem).initCapacity(a, order.len);
                for (order) |o_entry| {
                    const matched = for (image_files) |fh| {
                        const stem = if (std.mem.lastIndexOfScalar(u8, fh.filepath, '/')) |slash|
                            fh.filepath[slash + 1 ..]
                        else
                            fh.filepath;
                        const bare = if (std.mem.lastIndexOfScalar(u8, stem, '.')) |dot|
                            stem[0..dot]
                        else
                            stem;
                        if (std.mem.eql(u8, bare, o_entry.filename)) break fh;
                    } else {
                        log.warn("order entry '{s}' has no matching image, skipping", .{o_entry.filename});
                        continue;
                    };
                    try result.append(a, .{
                        .file = matched,
                        .text = o_entry.text,
                    });
                }
                break :blk try result.toOwnedSlice(a);
            } else unordered: {
                var result = try std.ArrayList(ImageItem).initCapacity(a, image_files.len);
                for (image_files) |fh|
                    try result.append(a, .{ .file = fh, .text = null });
                break :unordered try result.toOwnedSlice(a);
            };

            try templates.put(a, cat.*, .{
                .image_items = ordered,
                .info = category_data.info,
            });
        }

        return templates;
    }
};

// "https://drive.google.com/thumbnail?id=#{id}"
// pub fn deinitFilesMap(
//     a: std.mem.Allocator,
//     files_map: *FilesMap,
// ) void {
//     var iter = files_map.valueIterator();
//     while (iter.next()) |files|
//         files.deinit(a);

//     files_map.deinit(a);
// }

/// spawns one thread per category
pub const Info = struct {
    title: []const u8,
    body: []const u8,
};

pub fn parseInfo(input: []const u8) !Info {
    const title_prefix = "title:";
    const body_prefix = "body:";

    var lines = std.mem.splitScalar(u8, input, '\n');

    const title_line = lines.next() orelse return error.MissingTitle;

    if (!std.mem.startsWith(u8, title_line, title_prefix))
        return error.ExpectedTitle;

    const title = std.mem.trim(
        u8,
        title_line[title_prefix.len..],
        " \t",
    );

    const body_line = lines.next() orelse return error.MissingBody;

    if (!std.mem.startsWith(u8, body_line, body_prefix))
        return error.ExpectedBody;

    const body_offset =
        std.mem.indexOf(u8, input, body_line).? +
        body_prefix.len;

    const body = std.mem.trimStart(
        u8,
        input[body_offset..],
        " \t",
    );

    return .{
        .title = title,
        .body = body,
    };
}

pub const OrderEntry = struct {
    filename: []const u8,
    text: ?[]const u8,
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
                .filename = std.mem.trim(u8, split_first, " \t"),
                .text = std.mem.trim(u8, split.rest(), " \t"),
            });
        } else try list.append(a, OrderEntry{
            .filename = line,
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
