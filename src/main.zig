const std = @import("std");
const zap = @import("zap");
const zemplate = @import("zemplate");
const drive = @import("drive/root.zig");

const zyph = @import("zyph");
const Request = std.http.Server.Request;

pub const std_options = std.Options{
    .log_level = .debug,
    .log_scope_levels = &.{
        .{ .scope = .Lexer, .level = .warn },
        .{ .scope = .render, .level = .warn },
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
    const allocator = init.gpa;

    var server = zyph.Server.init(allocator, init.io, "serve");
    defer server.deinit();

    var client, const auth_header = try drive.remote.createClientAndAuthHeader(allocator, init.io, &(init.environ_map.*));
    defer client.deinit();
    defer allocator.free(auth_header.override);

    var drive_remote = try drive.remote.getRemoteCollections(
        allocator,
        &client,
        auth_header,
    );
    // defer drive_remote.deinit(allocator);
    std.log.debug(
        \\ created full files table
    , .{});

    var diff = try drive.local.diffRemoteCollections(allocator, init.io, &drive_remote);
    defer diff.deinit(allocator);

    for (diff.to_delete.items) |path| {
        std.Io.Dir.cwd().deleteFile(init.io, path) catch {};
    }

    try drive.remote.downloadFiles(
        allocator,
        auth_header,
        diff.to_download.items,
        8,
    );

    var drive_local = drive.local.getLocalCollections(allocator, init.io, drive_remote);
    defer drive_local.deinit(allocator);

    inline for (drive.ImageCategory.ALL_VARIANTS) |cat| {
        std.log.warn(
            \\ Category: {s}
            \\ Handle:
            \\ filepath: {s}
        , .{
            @tagName(cat),
            drive_local.getFieldConst(cat).*.handle.filepath,
            // drive_local.getFieldConst(cat).*.handle,
        });
    }
    var templates = try drive.templates.AllTemplates.createAllTemplates(allocator, drive_local);

    inline for (drive.ImageCategory.ALL_VARIANTS) |cat| {
        const T = switch (cat) {
            .editorial => drive.templates.Editorials,
            else => continue,
            // .portraits => @ptrCast(templates.portraits),
            // .sketch => @ptrCast(templates.sketch),
            // .unpublished => @ptrCast(templates.unpublished),
        };
        const inst: *anyopaque = switch (cat) {
            .editorial => @ptrCast(&templates.editorials),
            else => continue,
            // .portraits => @ptrCast(templates.portraits),
            // .sketch => @ptrCast(templates.sketch),
            // .unpublished => @ptrCast(templates.unpublished),
        };

        const handler = try server.registerHypermediaEndpoint("/" ++ titleCase(@tagName(cat)), inst, &struct {
            fn handler(obj: *T, a: std.mem.Allocator, _: Request, w: *std.Io.Writer) anyerror!void {
                var t = try zemplate.Template(T).init(a, obj.*);
                defer t.deinit();
                const render = try t.render(@embedFile(@tagName(cat) ++ ".html"), .{});
                try w.writeAll(render);
            }
        }.handler);
        try handler.addMiddlewares(.post, &.{zyph.hydration_middleware.NAME});
    }

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
