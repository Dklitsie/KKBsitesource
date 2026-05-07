const std = @import("std");
const log = std.log.scoped(.BlogsMetadata);
const Allocator = std.mem.Allocator;

const BLOG_DIR = "serve/blog";
const OUTFILE = "blogsMetadata.json";

pub const Metadata = struct {
    path: []const u8,
    last_modified: i64,
    created: i64 = 0,

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print(
            \\
            \\ path: {s}
            \\ last_modified: {d}
            \\ created: {d}
            \\
        , .{ self.path, self.last_modified, self.created });
    }
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const realpath = try std.fs.cwd().realpathAlloc(a, OUTFILE);

    const json_bytes = try createNewFileContent(a, realpath);
    var file = blk: {
        break :blk std.fs.cwd().openFile(OUTFILE, .{
            .mode = .read_write,
        }) catch |e| {
            if (e == error.FileNotFound) break :blk try std.fs.cwd().createFile(OUTFILE, .{});
            log.err(
                \\ Encountered unexpected error while opening file: {s}
            , .{@errorName(e)});
            return e;
        };
    };

    defer file.close();

    log.warn(
        \\ Writing to file: {s}
    , .{realpath});
    try file.writeAll(json_bytes);
}

fn createNewFileContent(a: Allocator, real_path: []const u8) anyerror![]u8 {
    const old_parsed = try getOutfileContent(a, real_path);
    defer if (old_parsed) |p| p.deinit();

    var created_map = std.StringHashMap(i64).init(a);
    defer created_map.deinit();

    if (old_parsed) |parsed|
        for (parsed.value) |item| if (item.created != 0) {
            log.warn(
                \\ Found existing metadata for {s} with created timestamp {d}
            , .{ item.path, item.created });
            try created_map.put(item.path, item.created);
        };

    const cwd = std.fs.cwd();
    var dir = try cwd.openDir(BLOG_DIR, .{ .iterate = true });
    var it = dir.iterate();

    var files = try std.ArrayList(Metadata).initCapacity(a, 64);

    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (entry.name[0] == '.') continue;

        const stat = try dir.statFile(entry.name);
        log.warn("{s} : {d}\n", .{ entry.name, stat.mtime });

        const created = created_map.get(entry.name) orelse
            @as(i64, @intCast(stat.mtime));

        try files.append(a, Metadata{
            .path = entry.name,
            .last_modified = @as(i64, @intCast(stat.mtime)),
            .created = created,
        });
    }

    var out: std.io.Writer.Allocating = .init(a);
    try std.json.Stringify.value(files.items, .{ .whitespace = .indent_2 }, &out.writer);

    const json_bytes = out.toOwnedSlice() catch @panic("out of memory");
    return json_bytes;
}

fn getOutfileContent(a: Allocator, real_path: []const u8) anyerror!?std.json.Parsed([]const Metadata) {
    const cwd = std.fs.cwd();
    const file = cwd.openFile(real_path, .{}) catch return null;
    defer file.close();
    const content = try file.readToEndAlloc(a, 2048);
    if (content.len == 0) {
        log.warn(
            \\ {s} is empty
        , .{real_path});
    }

    const parsed = try std.json.parseFromSlice([]const Metadata, a, content, .{});

    return parsed;
}

test "outfile parse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const metadata = (try getOutfileContent(a)) orelse return;
    defer metadata.deinit();

    std.debug.print(
        \\
        \\ METADATA:
    , .{});

    for (metadata.value) |item| {
        std.debug.print(
            \\ {f}
        , .{item});
    }

    // const map = try outfileContentToMap(a, metadata);
    // defer map.deinit(a);
}

test "create new content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const content = try createNewFileContent(a);
    std.debug.print(
        \\ {s}
    , .{content});
}
