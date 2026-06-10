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
const MimeOption = enum { folder, image };

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
        \\Error fetching folder
        \\status: {s}
        \\body: {s}
    , .{ @tagName(status), res_body });
    return error.StatusNotSuccess;
}

pub const FileHandle = struct {
    id: []u8,
    filepath: []u8,
};

// "https://drive.google.com/thumbnail?id=#{id}"
pub fn deinitFilesMap(
    a: std.mem.Allocator,
    files_map: *std.StringHashMapUnmanaged([]FileHandle),
) void {
    var iter = files_map.valueIterator();
    while (iter.next()) |files| {
        for (files.*) |f| {
            a.free(f.id);
            a.free(f.filepath);
        }
    }
    files_map.deinit(a);
}

pub fn getFilesMap(
    a: std.mem.Allocator,
    folder_id: []const u8,
    client: *std.http.Client,
    authorization_header: std.http.Client.Request.Headers.Value,
) anyerror!std.StringHashMapUnmanaged([]FileHandle) {
    const parsed = try getFolderFilesMatchingMime(
        a,
        client,
        authorization_header,
        folder_id,
        .folder,
    );
    defer parsed.deinit();

    var files_map = std.StringHashMapUnmanaged([]FileHandle){};

    inline for ([_]ImageCategory{ .editorial, .picture_book, .portraits, .sketch }) |category| {
        const category_str = @tagName(category);
        for (parsed.value.files) |f| {
            if (std.mem.eql(u8, f.name, category_str)) {
                std.debug.print("found {s}: {s}\n", .{ category_str, f.id });

                const files = try getFolderFilesMatchingMime(a, client, authorization_header, f.id, .image);
                defer files.deinit();

                const file_handles = try a.alloc(FileHandle, files.value.files.len);

                for (files.value.files, 0..) |file, i| {
                    file_handles[i] = .{
                        .id = try a.dupe(u8, file.id),
                        .filepath = try std.fmt.allocPrint(a, "{s}/{s}", .{ category_str, file.name }),
                    };
                }
                try files_map.put(a, category_str, file_handles);
            }
        }
    }

    return files_map;
}

/// make sure to free authorization_header.override
pub fn createClientAndAuthHeader(a: std.mem.Allocator) anyerror!struct { std.http.Client, std.http.Client.Request.Headers.Value } {
    var env_map = try std.process.getEnvMap(a);
    defer env_map.deinit();

    const result = try std.process.Child.run(.{
        .allocator = a,
        .argv = &.{ "/bin/bash", "get-drive-token.sh" },
        .env_map = &env_map,
    });
    defer a.free(result.stdout);
    defer a.free(result.stderr);
    const access_token = std.mem.trim(u8, result.stdout, "\n");
    log.warn("Access Token: {s}", .{access_token});

    // const access_token = env_map.get("ACCESS_TOKEN") orelse @panic("No Access Token");

    const authorization_header_str = try std.fmt.allocPrint(a, "Bearer {s}", .{access_token});
    const authorization_header = std.http.Client.Request.Headers.Value{ .override = authorization_header_str };

    const client = std.http.Client{
        .allocator = a,
        // must be explicitly set to avoid an indefinte hang
        .write_buffer_size = 1024 * 32,
    };
    return .{ client, authorization_header };
}

const SyncContext = struct {
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    auth_header: std.http.Client.Request.Headers.Value,

    category: ImageCategory,
    files: []FileHandle,
};

const WorkItem = struct {
    category: []const u8,
    file: DriveFile,
};

fn downloadFile(
    a: std.mem.Allocator,
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

    // Skip existing files.
    std.fs.cwd().access(output_path, .{}) catch {
        var parent_dir = std.mem.splitScalar(u8, file_handle.filepath, '/');
        const dir_path = try std.fmt.allocPrint(
            a,
            "serve/imgs/{s}",
            .{parent_dir.first()},
        );
        defer a.free(dir_path);

        try std.fs.cwd().makePath(dir_path);

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

        var out = try std.fs.cwd().createFile(output_path, .{});
        defer out.close();

        try out.writeAll(body);

        log.info("downloaded {s}", .{output_path});
    };
}

fn worker(ctx: *SyncContext) !void {
    defer ctx.allocator.destroy(ctx);
    for (ctx.files) |file| {
        try downloadFile(
            ctx.allocator,
            ctx.client,
            ctx.auth_header,
            file,
        );
    }
}

/// spawns one thread per category
pub fn syncImages(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    auth_header: std.http.Client.Request.Headers.Value,
    files_map: *const std.StringHashMapUnmanaged([]FileHandle),
) anyerror!void {
    const threads = try allocator.alloc(std.Thread, std.meta.tags(ImageCategory).len);
    defer allocator.free(threads);

    for (threads, std.meta.tags(ImageCategory)) |*thread, category| {
        const ctx = try allocator.create(SyncContext);

        ctx.* = .{
            .allocator = allocator,
            .client = client,
            .auth_header = auth_header,
            .files = files_map.get(@tagName(category)).?,
            .category = category,
        };
        thread.* = try std.Thread.spawn(
            .{},
            worker,
            .{ctx},
        );
    }

    for (threads) |thread| {
        thread.join();
    }
}

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

    const body = std.mem.trimLeft(
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
