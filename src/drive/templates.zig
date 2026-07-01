const std = @import("std");
const root = @import("root.zig");
const zemplate = @import("zemplate");
const log = std.log.scoped(.drive_templates);

pub const Editorials = struct {
    /// Editorial collections either have issues or just images
    const Collection = struct {
        images: ?[]root.local.ImageItem,
        issues: ?[]Issue,
        template: root.CollectionTemplate,
    };

    const Issue = struct {
        images: []root.local.ImageItem,
        template: root.CollectionTemplate,
    };

    handle: root.FileHandle,
    children: []Collection,
    template: root.CollectionTemplate,
};

pub const AllTemplates = struct {
    editorials: Editorials,

    pub fn createAllTemplates(a: std.mem.Allocator, local_collections: root.local.LocalCollections) anyerror!@This() {
        var editorials: Editorials = undefined;

        inline for (root.ImageCategory.ALL_VARIANTS) |cat| {
            const collection = local_collections.getFieldConst(cat);
            switch (cat) {
                .editorial => {
                    const collection_children = collection.collections orelse {
                        log.err(
                            \\ Editorials is missing child collections
                        , .{});
                        return error.MissingCollections;
                    };
                    const child_collections = try a.alloc(Editorials.Collection, collection_children.len);

                    for (child_collections, collection_children) |*ch, coll_ch| {
                        const inner = coll_ch.collection;

                        if (inner.collections) |issues| {
                            // this year has sub-issues
                            const issue_list = try a.alloc(Editorials.Issue, issues.len);
                            for (issue_list, issues) |*issue, issue_ch| {
                                issue.* = .{
                                    .images = issue_ch.collection.images orelse {
                                        log.err(
                                            \\ child: {s} does not have images? 
                                        , .{issue_ch.collection.handle.filepath});
                                        return error.MissingImages;
                                    },
                                    .template = issue_ch.collection.template,
                                };
                            }
                            ch.* = .{
                                .images = null,
                                .issues = issue_list,
                                .template = inner.template,
                            };
                        } else {
                            ch.* = .{
                                .images = inner.images,
                                .issues = null,
                                .template = inner.template,
                            };
                        }
                    }

                    editorials = .{
                        .handle = collection.handle,
                        .children = child_collections,
                        .template = collection.template,
                    };
                },
                .unpublished => {},
                .sketch => {},
                .portraits => {},
            }
        }

        return .{
            .editorials = editorials,
        };
    }
};
