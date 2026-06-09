const std = @import("std");
const zap = @import("zap");
const zemplate = @import("zemplate");
const drive = @import("drive.zig");
const zyph = @import("zyph");
const Request = std.http.Server.Request;

pub const std_options = std.Options{
    // .log_level = .debug,
    .log_level = .warn,
};

const EmptyTemplate = zemplate.Template(@TypeOf(.{}));

const ImagesPage = struct {
    image_items: []const drive.FileHandle,
};

inline fn titleCase(comptime s: []const u8) [calcTitleCaseLen(s)]u8 {
    var result: [calcTitleCaseLen(s)]u8 = undefined;
    var i: usize = 0;
    var capitalize = true;
    for (s) |c| {
        if (c == '_') {
            capitalize = true;
            continue;
        }
        result[i] = if (capitalize) std.ascii.toUpper(c) else c;
        capitalize = false;
        i += 1;
    }
    return result;
}

inline fn calcTitleCaseLen(comptime s: []const u8) usize {
    var len = 0;
    for (s) |c| {
        if (c != '_') len += 1;
    }
    return len;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .thread_safe = true,
    }){};
    defer if (gpa.detectLeaks()) std.log.err("LEAKS DETECTED IN MAIN ALLOCATOR\n", .{});

    const allocator = gpa.allocator();
    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();

    var server = zyph.Server.init(allocator, "serve");
    defer server.deinit();

    var client, const auth_header = try drive.createClientAndAuthHeader(allocator);
    defer client.deinit();
    defer allocator.free(auth_header.override);
    const drive_folder_id = env_map.get("FOLDER_ID") orelse @panic("No Folder Id");
    var thumbnail_urls = try drive.getFilesMap(
        allocator,
        drive_folder_id,
        &client,
        auth_header,
    );
    defer drive.deinitFilesMap(allocator, &thumbnail_urls);

    try drive.syncImages(allocator, &client, auth_header, &thumbnail_urls);

    const editorial_imgs = thumbnail_urls.get(@tagName(drive.ImageCategory.editorial)).?;
    for (editorial_imgs) |img| {
        std.log.info(
            \\file: {s} 
        , .{img.filepath});
    }
    var editorial = ImagesPage{ .image_items = editorial_imgs };
    const picture_book_imgs = thumbnail_urls.get(@tagName(drive.ImageCategory.picture_book)).?;
    var picture_book = ImagesPage{ .image_items = picture_book_imgs };
    const sketch_imgs = thumbnail_urls.get(@tagName(drive.ImageCategory.sketch)).?;
    var sketch = ImagesPage{ .image_items = sketch_imgs };
    const portraits_imgs = thumbnail_urls.get(@tagName(drive.ImageCategory.portraits)).?;
    var portraits = ImagesPage{ .image_items = portraits_imgs };

    var hydration_context = try zyph.hydration_middleware.Context.init(
        allocator,
        "components",
        try std.fs.cwd().openFile("pages/index.html", .{}),
    );
    defer hydration_context.deinit(allocator);
    try server.middlewares.put(
        zyph.hydration_middleware.NAME,
        zyph.Middleware.init(.post, &hydration_context, &zyph.hydration_middleware.handler),
    );

    inline for ([_]drive.ImageCategory{ .editorial, .picture_book, .portraits, .sketch }) |category| {
        const page = switch (category) {
            .editorial => &editorial,
            .picture_book => &picture_book,
            .portraits => &portraits,
            .sketch => &sketch,
        };
        const handler = try server.registerHypermediaEndpoint("/" ++ titleCase(@tagName(category)), page, &struct {
            fn handler(obj: *ImagesPage, a: std.mem.Allocator, _: Request, w: *std.Io.Writer) anyerror!void {
                var t = try zemplate.Template(ImagesPage).init(a, obj.*);
                defer t.deinit();
                const render = try t.render(@embedFile(@tagName(category) ++ ".html"), .{});
                try w.writeAll(render);
            }
        }.handler);
        try handler.addMiddlewares(.post, &.{zyph.hydration_middleware.NAME});
    }

    for (&[_]zyph.Server.RouteHandler{
        try server.registerHypermediaEndpoint("/", &.{}, &struct {
            fn handler(obj: *@TypeOf(.{}), a: std.mem.Allocator, _: Request, w: *std.Io.Writer) anyerror!void {
                var t = try EmptyTemplate.init(a, obj.*);
                defer t.deinit();
                const render = try t.render(@embedFile("home.html"), .{});
                try w.writeAll(render);
            }
        }.handler),

        try server.registerHypermediaEndpoint("/Info", &.{}, &struct {
            fn handler(obj: *@TypeOf(.{}), a: std.mem.Allocator, _: Request, w: *std.Io.Writer) anyerror!void {
                var t = try EmptyTemplate.init(a, obj.*);
                defer t.deinit();
                const render = try t.render(@embedFile("info.html"), .{});
                try w.writeAll(render);
            }
        }.handler),
    }) |route_handler| {
        try route_handler.addMiddlewares(.post, &.{zyph.hydration_middleware.NAME});
    }

    const port_str = env_map.get("PORT") orelse "3000";
    const port = try std.fmt.parseInt(u16, port_str, 10);
    const addr = try std.net.Address.parseIp("0.0.0.0", port);
    try server.startServer(addr, .{ .reuse_address = true });

    try server.listen();
}

test {
    std.testing.refAllDecls(@This());
}
