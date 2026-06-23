const std = @import("std");
const zap = @import("zap");
const zemplate = @import("zemplate");
const drive = @import("drive.zig");
const zyph = @import("zyph");
const Request = std.http.Server.Request;

pub const std_options = std.Options{
    .log_level = .debug,
    .log_scope_levels = &.{
        .{ .scope = .Lexer, .level = .warn },
        .{ .scope = .Scope, .level = .warn },
    },
};

const EmptyTemplate = zemplate.Template(@TypeOf(.{}));

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

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    var server = zyph.Server.init(allocator, init.io, "serve");
    defer server.deinit();

    var client, const auth_header = try drive.createClientAndAuthHeader(allocator, init.io);
    defer client.deinit();
    defer allocator.free(auth_header.override);
    const drive_folder_id = init.environ_map.get("FOLDER_ID") orelse @panic("No Folder Id");

    var category_data = try drive.CategoryData.build(allocator, init.io, &client, auth_header, drive_folder_id);
    defer category_data.deinit(allocator);
    try category_data.syncImages(allocator, init.io, auth_header);

    var templates = try category_data.createOrderedTemplates(allocator);
    defer templates.deinit(allocator);

    var editorial = templates.get(@tagName(drive.ImageCategory.editorial)).?;
    var unpub_illustration = templates.get(@tagName(drive.ImageCategory.unpub_illustration)).?;
    var sketch = templates.get(@tagName(drive.ImageCategory.sketch)).?;
    var portraits = templates.get(@tagName(drive.ImageCategory.portraits)).?;

    var hydration_context = try zyph.hydration_middleware.Context.init(
        allocator,
        init.io,
        "components",
        try std.Io.Dir.cwd().openFile(init.io, "pages/index.html", .{}),
    );
    defer hydration_context.deinit(allocator);
    try server.middlewares.put(
        zyph.hydration_middleware.NAME,
        zyph.Middleware.init(.post, &hydration_context, &zyph.hydration_middleware.handler),
    );

    inline for ([_]drive.ImageCategory{ .editorial, .unpub_illustration, .portraits, .sketch }) |category| {
        const page = switch (category) {
            .editorial => &editorial,
            .unpub_illustration => &unpub_illustration,
            .portraits => &portraits,
            .sketch => &sketch,
        };
        const handler = try server.registerHypermediaEndpoint("/" ++ titleCase(@tagName(category)), page, &struct {
            fn handler(obj: *drive.PageZemplate, a: std.mem.Allocator, _: Request, w: *std.Io.Writer) anyerror!void {
                var t = try zemplate.Template(drive.PageZemplate).init(a, obj.*);
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

    const port_str = init.environ_map.get("PORT") orelse "3000";
    const port = try std.fmt.parseInt(u16, port_str, 10);
    const addr = try std.Io.net.IpAddress.parse("0.0.0.0", port);
    try server.startServer(&addr, .{ .reuse_address = true });

    try server.listen();
}

test {
    std.testing.refAllDecls(@This());
}
