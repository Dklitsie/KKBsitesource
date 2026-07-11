const std = @import("std");
const log = std.log.scoped(.drive_local);
const root = @import("root.zig");

pub const ImageItem = struct { file: root.FileHandle, text: ?[]const u8 };
pub const CollectionItem = struct { collection: LocalCollection, text: ?[]const u8 };
pub const LocalCollection = struct {
    handle: root.FileHandle,
    images: ?[]ImageItem,
    collections: ?[]CollectionItem,
    template: root.CollectionTemplate,

    pub fn deinit(self: *@This(), a: std.mem.Allocator) void {
        self.handle.deinit(a);
        if (self.collections) |cs| {
            defer a.free(cs);
            for (cs) |*col| col.collection.deinit(a);
        }
        if (self.images) |imgs| {
            defer a.free(imgs);
        }

        self.template.deinit(a);
    }

    pub fn fromRemote(a: std.mem.Allocator, io: std.Io, remote: root.remote.RemoteCollection) !@This() {
        log.debug(
            \\ creating local collection from remote: {s}
        , .{remote.handle.filepath});
        const template = blk: {
            if (remote.template) |tmp| {
                const file = try std.Io.Dir.cwd().openFile(io, tmp.filepath, .{});
                defer file.close(io);
                const transfer_buffer = try a.alloc(u8, 1024 * 1024);
                defer a.free(transfer_buffer);
                var reader = file.reader(io, transfer_buffer);
                const template_txt = try reader.interface.allocRemaining(a, .unlimited);

                break :blk try root.CollectionTemplate.parse(
                    a,
                    template_txt,
                    .{
                        .title = remote.handle.name,
                    },
                );
            }

            log.warn(
                \\ creating default template for local collection: {s}
            , .{remote.handle.name});

            const info = root.CollectionTemplate.Info{
                .title = try a.dupe(u8, remote.handle.name),
            };
            break :blk root.CollectionTemplate{ .info = info };
        };

        const image_items: ?[]ImageItem = blk: {
            if (remote.images == null) break :blk null;
            if (template.order != null) {
                var used = std.StringHashMap(void).init(a);
                defer used.deinit();
                const order = template.order.?;
                var result = try std.ArrayList(ImageItem).initCapacity(a, order.len);
                for (order) |o_entry| {
                    const matched = match: {
                        for (remote.images.?) |*fh| {
                            if (used.contains(fh.filepath)) continue;
                            {
                                const webp_path = (try fh.webpPath(a)).?;
                                a.free(fh.*.filepath);
                                fh.*.filepath = webp_path;
                            }

                            const stem = if (std.mem.lastIndexOfScalar(u8, fh.filepath, '/')) |slash|
                                fh.filepath[slash + 1 ..]
                            else
                                fh.filepath;
                            const bare = if (std.mem.lastIndexOfScalar(u8, stem, '.')) |dot|
                                stem[0..dot]
                            else
                                stem;

                            if (std.ascii.startsWithIgnoreCase(bare, o_entry.filename)) {
                                try used.put(fh.filepath, {});
                                break :match fh.*;
                            }
                        } else {
                            log.warn("order entry '{s}' has no matching image, skipping", .{o_entry.filename});
                            continue;
                        }
                    };
                    log.warn("matched image: {s}", .{matched.filepath});
                    try result.append(a, .{ .file = matched, .text = o_entry.text });
                }

                for (remote.images.?) |*fh| {
                    if (used.contains(fh.filepath)) continue;

                    {
                        const webp_path = (try fh.webpPath(a)).?;
                        a.free(fh.*.filepath);
                        fh.*.filepath = webp_path;
                    }

                    try result.append(a, .{ .file = fh.*, .text = null });
                }

                break :blk try result.toOwnedSlice(a);
            } else {
                var result = try std.ArrayList(ImageItem).initCapacity(a, remote.images.?.len);
                for (remote.images.?) |fh| {
                    try result.append(a, .{ .file = fh, .text = null });
                }
                break :blk try result.toOwnedSlice(a);
            }
        };
        const coll_items: ?[]CollectionItem = blk: {
            if (remote.collections == null) break :blk null;
            if (template.order != null) {
                var used = std.StringHashMap(void).init(a);
                defer used.deinit();
                const order = template.order.?;
                var result = try std.ArrayList(CollectionItem).initCapacity(a, order.len);
                for (order) |o_entry| {
                    const matched = match: {
                        for (remote.collections.?) |*coll| {
                            const stem = if (std.mem.lastIndexOfScalar(u8, coll.handle.filepath, '/')) |slash|
                                coll.handle.filepath[slash + 1 ..]
                            else
                                coll.handle.filepath;
                            if (std.ascii.startsWithIgnoreCase(stem, o_entry.filename)) {
                                try used.put(coll.handle.filepath, {});
                                break :match coll;
                            }
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

                for (remote.collections.?) |coll| {
                    if (used.contains(coll.handle.filepath)) continue;
                    try result.append(a, .{
                        .collection = try LocalCollection.fromRemote(a, io, coll),
                        .text = null,
                    });
                }
                break :blk try result.toOwnedSlice(a);
            } else {
                var result = try std.ArrayList(CollectionItem).initCapacity(a, remote.collections.?.len);
                for (remote.collections.?) |*coll|
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
    .template = undefined,
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
    if (collection.images) |imgs| {
        for (imgs) |img| {
            const local_path = try std.fmt.allocPrint(a, root.DRIVE_DIR ++ "{s}", .{img.filepath});
            defer a.free(local_path);
            if (local_files.fetchRemove(local_path)) |_| {
                // exists locally, up to date
            } else {
                try result.to_download.append(a, img);
            }
        }
    }
    if (collection.collections) |colls| {
        for (colls) |*coll| {
            try diffCollection(a, coll, local_files, result);
        }
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
