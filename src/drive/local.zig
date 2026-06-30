const std = @import("std");
const log = std.log.scoped(.drive_local);
const root = @import("root.zig");

pub const ImageItem = struct { file: root.FileHandle, text: ?[]const u8 };
pub const CollectionItem = struct { collection: LocalCollection, text: ?[]const u8 };
pub const LocalCollection = struct {
    handle: root.FileHandle,
    // remote should have this pattern rather than child
    images: ?[]ImageItem,
    collections: ?[]CollectionItem,
    template: ?root.CollectionTemplate,

    pub fn deinit(self: *@This(), a: std.mem.Allocator) void {
        self.handle.deinit(a);
        if (self.collections) |cs| {
            defer a.free(cs);
            for (cs) |*col| col.collection.deinit(a);
        }
        if (self.images) |imgs| {
            defer a.free(imgs);
        }

        if (self.template) |*t| t.deinit(a);
    }

    pub fn fromRemote(a: std.mem.Allocator, io: std.Io, remote: root.remote.RemoteCollection) !@This() {
        log.warn(
            \\ creating local collection from remote: {s}
        , .{remote.handle.filepath});
        var template: ?root.CollectionTemplate = null;
        if (remote.template) |tmp| {
            const file = try std.Io.Dir.cwd().openFile(io, tmp.filepath, .{});
            defer file.close(io);
            const transfer_buffer = try a.alloc(u8, 1024 * 1024);
            defer a.free(transfer_buffer);
            var reader = file.reader(io, transfer_buffer);

            template = try root.CollectionTemplate.parse(a, try reader.interface.allocRemaining(a, .unlimited), .{
                .title = tmp.filepath,
            });
        }

        const image_items: ?[]ImageItem = blk: {
            if (remote.child != .images) break :blk null;
            if (template != null and template.?.order != null) {
                const order = template.?.order.?;
                var result = try std.ArrayList(ImageItem).initCapacity(a, order.len);
                for (order) |o_entry| {
                    const matched = match: {
                        for (remote.child.images) |fh| {
                            const stem = if (std.mem.lastIndexOfScalar(u8, fh.filepath, '/')) |slash|
                                fh.filepath[slash + 1 ..]
                            else
                                fh.filepath;
                            const bare = if (std.mem.lastIndexOfScalar(u8, stem, '.')) |dot|
                                stem[0..dot]
                            else
                                stem;
                            if (std.ascii.eqlIgnoreCase(bare, o_entry.filename)) break :match fh;
                        } else {
                            log.warn("order entry '{s}' has no matching image, skipping", .{o_entry.filename});
                            continue;
                        }
                    };
                    try result.append(a, .{ .file = matched, .text = o_entry.text });
                }
                break :blk try result.toOwnedSlice(a);
            } else {
                var result = try std.ArrayList(ImageItem).initCapacity(a, remote.child.images.len);
                for (remote.child.images) |fh|
                    try result.append(a, .{ .file = fh, .text = null });
                break :blk try result.toOwnedSlice(a);
            }
        };
        const coll_items: ?[]CollectionItem = blk: {
            if (remote.child != .collections) break :blk null;
            if (template != null and template.?.order != null) {
                const order = template.?.order.?;
                var result = try std.ArrayList(CollectionItem).initCapacity(a, order.len);
                for (order) |o_entry| {
                    const matched = match: {
                        for (remote.child.collections) |*coll| {
                            const stem = if (std.mem.lastIndexOfScalar(u8, coll.handle.filepath, '/')) |slash|
                                coll.handle.filepath[slash + 1 ..]
                            else
                                coll.handle.filepath;
                            if (std.ascii.eqlIgnoreCase(stem, o_entry.filename)) break :match coll;
                        } else {
                            log.warn("order entry '{s}' has no matching collection, skipping", .{o_entry.filename});
                            continue;
                        }
                    };
                    const coll_item: CollectionItem = .{
                        .collection = try LocalCollection.fromRemote(a, io, matched.*),
                        .text = o_entry.text,
                    };
                    try result.append(a, coll_item);
                }
                break :blk try result.toOwnedSlice(a);
            } else {
                var result = try std.ArrayList(CollectionItem).initCapacity(a, remote.child.collections.len);
                for (remote.child.collections) |*coll|
                    try result.append(a, .{
                        .collection = try LocalCollection.fromRemote(a, io, coll.*),
                        .text = null,
                    });
                break :blk try result.toOwnedSlice(a);
            }
        };

        return @This(){
            .handle = remote.handle,
            .images = image_items,
            .collections = coll_items,
            .template = template,
        };
    }
};

pub const LocalCollections = root.ImageCategory.Plexe(LocalCollection, &.{
    .handle = undefined,
    .images = undefined,
    .collections = undefined,
    .template = null,
});

pub fn getLocalCollections(a: std.mem.Allocator, io: std.Io, remote: root.remote.RemoteCollections) LocalCollections {
    var result = LocalCollections{};
    inline for (root.ImageCategory.ALL_VARIANTS) |cat| {
        result.getField(cat).* = LocalCollection.fromRemote(a, io, remote.getFieldConst(cat).*) catch {
            std.debug.panic(
                \\ Failed to get local collection for {s}
            , .{@tagName(cat)});
        };
    }
    return result;
}

pub const DiffResult = struct {
    to_download: std.ArrayList(root.FileHandle),
    to_delete: std.ArrayList([]const u8),

    pub fn deinit(self: *@This(), a: std.mem.Allocator) void {
        self.to_download.deinit(a);
        self.to_delete.deinit(a);
    }
};

fn collectLocalFiles(
    a: std.mem.Allocator,
    io: std.Io,
) !std.StringHashMapUnmanaged(void) {
    var local = std.StringHashMapUnmanaged(void){};
    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, root.DRIVE_DIR, .{ .iterate = true }) catch return local;
    defer dir.close(io);

    var walker = try dir.walk(a);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const full = try std.fmt.allocPrint(a, "{s}/{s}", .{ root.DRIVE_DIR, entry.path });
        try local.put(a, full, {});
    }
    return local;
}

fn diffCollection(
    a: std.mem.Allocator,
    collection: *const root.remote.RemoteCollection,
    local_files: *std.StringHashMapUnmanaged(void),
    result: *DiffResult,
) !void {
    switch (collection.child) {
        .images => |imgs| {
            for (imgs) |img| {
                const local_path = try std.fmt.allocPrint(a, root.DRIVE_DIR ++ "{s}", .{img.filepath});
                defer a.free(local_path);
                if (local_files.fetchRemove(local_path)) |_| {
                    // exists locally, up to date
                } else {
                    try result.to_download.append(a, img);
                }
            }
        },
        .collections => |colls| {
            for (colls) |*coll| {
                try diffCollection(a, coll, local_files, result);
            }
        },
    }
    if (collection.template) |tmpl| {
        if (local_files.fetchRemove(tmpl.filepath)) |_| {
            // exists locally
        } else {
            try result.to_download.append(a, tmpl);
        }
    }
}

pub fn diffRemoteCollections(
    a: std.mem.Allocator,
    io: std.Io,
    table: *const root.remote.RemoteCollections,
) !DiffResult {
    var result = DiffResult{
        .to_download = std.ArrayList(root.FileHandle).empty,
        .to_delete = std.ArrayList([]const u8).empty,
    };
    var local_files = try collectLocalFiles(a, io);
    defer {
        var iter = local_files.keyIterator();
        while (iter.next()) |k| a.free(k.*);
        local_files.deinit(a);
    }

    inline for (root.ImageCategory.ALL_VARIANTS) |cat| {
        const entry = table.getFieldConst(cat);
        try diffCollection(a, entry, &local_files, &result);
    }

    // anything left in local wasn't in the table — stale
    var iter = local_files.keyIterator();
    while (iter.next()) |k| {
        try result.to_delete.append(a, k.*);
    }
    return result;
}
