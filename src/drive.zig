const std = @import("std");
const zemplate = @import("zemplate");
const zyph = @import("zyph");
const dotenv = @import("dotenv");
const print = std.debug.print;
const log = std.log.scoped(.images);
const Request = std.http.Server.Request;

pub const DriveFile = struct {
    kind: []u8,
    mimeType: []u8,
    id: []u8,
    name: []u8,
};
const DriveResponse = struct {
    files: []DriveFile,
};

const ImageCategories = enum {
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

// "https://drive.google.com/thumbnail?id=#{id}"

pub fn deinitFilesMap(
    a: std.mem.Allocator,
    files_map: *std.StringHashMapUnmanaged([]DriveFile),
) void {
    var iter = files_map.valueIterator();
    while (iter.next()) |files| {
        for (files.*) |f| {
            a.free(f.kind);
            a.free(f.mimeType);
            a.free(f.id);
            a.free(f.name);
        }
    }
    files_map.deinit(a);
}

pub fn getFilesMap(
    a: std.mem.Allocator,
) anyerror!std.StringHashMapUnmanaged([]DriveFile) {
    var env_map = try std.process.getEnvMap(a);
    defer env_map.deinit();
    const access_token = env_map.get("ACCESS_TOKEN") orelse @panic("No Access Token");
    const folder_id = env_map.get("FOLDER_ID") orelse @panic("No Folder Id");

    const authorization_header_str = try std.fmt.allocPrint(a, "Bearer {s}", .{access_token});
    defer a.free(authorization_header_str);
    const authorization_header = std.http.Client.Request.Headers.Value{ .override = authorization_header_str };

    var client = std.http.Client{
        .allocator = a,
        // must be explicitly set to avoid an indefinte hang
        .write_buffer_size = 1024 * 32,
    };
    defer client.deinit();

    const parsed = try getFolderFilesMatchingMime(a, &client, authorization_header, folder_id, .folder);
    defer parsed.deinit();

    var files_map = std.StringHashMapUnmanaged([]DriveFile){};
    inline for ([_]ImageCategories{ .picture_book, .sketch, .editorial, .portraits }) |category| {
        const category_str = @tagName(category);
        for (parsed.value.files) |f| {
            if (std.mem.eql(u8, f.name, category_str)) {
                std.debug.print("found {s}: {s}\n", .{ category_str, f.id });

                const files = try getFolderFilesMatchingMime(a, &client, authorization_header, f.id, .image);
                // defer files.deinit();
                try files_map.put(a, category_str, files.value.files);
            }
        }
    }

    return files_map;
}
