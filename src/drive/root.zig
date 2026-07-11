const std = @import("std");
const log = std.log.scoped(.drive);
pub const remote = @import("remote.zig");
pub const templates = @import("templates.zig");
pub const local = @import("local.zig");

pub const DRIVE_DIR = "serve/drive";

pub const ImageCategory = enum {
    unpublished,
    sketch,
    editorial,
    portraits,

    pub const ALL_VARIANTS = std.meta.tags(@This());

    /// Creates a struct with identical fields named after variants of ImageCategory
    pub inline fn Plexe(T: type, default_value: *const T) type {
        var field_names: [ALL_VARIANTS.len][]const u8 = undefined;
        var field_types: [ALL_VARIANTS.len]type = undefined;
        var field_attrs: [ALL_VARIANTS.len]std.builtin.Type.StructField.Attributes = undefined;

        inline for (ALL_VARIANTS, 0..) |cat, i| {
            field_names[i] = @tagName(cat);
            field_types[i] = T;
            field_attrs[i] = std.builtin.Type.StructField.Attributes{
                .@"align" = @alignOf(T),
                .default_value_ptr = @ptrCast(default_value),
            };
        }

        const S = @Struct(.auto, null, &field_names, &field_types, &field_attrs);

        return struct {
            plexe: S = .{},

            pub fn deinit(self: *@This(), a: std.mem.Allocator) void {
                const type_info = @typeInfo(T);
                if (@hasDecl(T, "deinit")) {
                    inline for (ALL_VARIANTS) |category| {
                        self.getField(category).deinit(a);
                    }
                } else if (type_info == .array) {
                    inline for (ALL_VARIANTS) |category| {
                        a.free(self.getField(category));
                    }
                } else log.debug(
                    \\ No deinit function for plexe built with {s}
                , .{@typeName(T)});
            }

            pub fn getField(
                self: *@This(),
                category: ImageCategory,
            ) *T {
                return &switch (category) {
                    .unpublished => self.plexe.unpublished,
                    .sketch => self.plexe.sketch,
                    .editorial => self.plexe.editorial,
                    .portraits => self.plexe.portraits,
                };
            }

            pub fn getFieldConst(
                self: *const @This(),
                category: ImageCategory,
            ) *const T {
                return &switch (category) {
                    .unpublished => self.plexe.unpublished,
                    .sketch => self.plexe.sketch,
                    .editorial => self.plexe.editorial,
                    .portraits => self.plexe.portraits,
                };
            }
        };
    }
};

pub const FileHandle = struct {
    id: []u8,
    filepath: []u8,
    name: []u8,
    modifiedTime: []u8,
    kind: remote.MimeOption,

    pub fn deinit(self: *@This(), a: std.mem.Allocator) void {
        a.free(self.id);
        a.free(self.filepath);
        a.free(self.name);
        a.free(self.modifiedTime);
    }

    pub fn webpPath(self: @This(), a: std.mem.Allocator) std.mem.Allocator.Error!?[]u8 {
        if (std.mem.findScalar(u8, self.filepath, '.') == null) {
            log.err(
                \\ called webpPath on file without extension: 
                \\ path: {s}
                \\ name: {s}
            , .{ self.filepath, self.name });
            return null;
        }
        var iter = std.mem.splitBackwardsScalar(u8, self.filepath, '.');
        _ = iter.first();
        return try std.fmt.allocPrint(a, "{s}.webp", .{iter.rest()});
    }
};

// move to local?
// should be made non null as a field in other structs and info should just be given a comptime known default
pub const CollectionTemplate = struct {
    info: Info,
    order: ?[]OrderEntry = null,
    const SEPARATOR = "-";

    pub fn deinit(self: *@This(), a: std.mem.Allocator) void {
        self.info.deinit(a);
        if (self.order) |order| for (order) |*e| e.deinit(a);
    }

    /// parses for Template with fallback info
    /// fallback will overwrite any null info fields
    /// should break apart two halves by -\n
    pub fn parse(
        a: std.mem.Allocator,
        text: []const u8,
        info_fallback: Info,
    ) !@This() {
        const sep_idx = blk: {
            var line_start: usize = 0;
            while (line_start < text.len) {
                const line_end =
                    std.mem.indexOfScalarPos(u8, text, line_start, '\n') orelse text.len;

                const line =
                    std.mem.trim(u8, text[line_start..line_end], &std.ascii.whitespace);

                if (std.mem.eql(u8, line, "-"))
                    break :blk line_start;

                line_start = if (line_end == text.len)
                    text.len
                else
                    line_end + 1;
            }

            break :blk text.len;
        };

        const info_text = text[0..sep_idx];

        const order_text =
            if (sep_idx == text.len)
                null
            else blk: {
                const after_sep = std.mem.indexOfScalarPos(u8, text, sep_idx, '\n') orelse text.len - 1;
                break :blk text[after_sep + 1 ..];
            };

        var info = Info.parse(a, info_text);

        if (info.title == null) {
            log.warn(
                \\ using fallback title
            , .{});
            info.title = info_fallback.title;
        }
        if (info.body == null) {
            log.warn(
                \\ using fallback body
            , .{});
            info.body = info_fallback.body;
        }

        return .{
            .info = info,
            .order = if (order_text) |txt| try OrderEntry.parseArray(a, txt) else null,
        };
    }

    pub const Info = struct {
        title: ?[]u8,
        body: ?[]u8 = null,
        pub fn deinit(self: *Info, a: std.mem.Allocator) void {
            if (self.title) |title| a.free(title);
            if (self.body) |body| a.free(body);
        }

        pub fn format(self: @This(), w: *std.Io.Writer) !void {
            try w.writeAll(
                \\ INFO
            );
            if (self.title) |t|
                try w.print(
                    \\ TITLE: {s}
                , .{t});

            if (self.body) |b| try w.print(
                \\ BODY: {s}
            , .{b});
        }

        pub fn parse(a: std.mem.Allocator, input: []const u8) @This() {
            const title_prefix = "title:";
            const body_prefix = "body:";

            var lines = std.mem.splitScalar(u8, input, '\n');
            const title = title: {
                var title_line = lines.first();
                if (std.mem.trim(u8, title_line, &std.ascii.whitespace).len == 0)
                    title_line = lines.next() orelse break :title null;

                title_line = std.mem.trimStart(u8, title_line, " \n\t");

                if (std.ascii.findIgnoreCase(title_line, title_prefix)) |idx| {
                    break :title std.mem.trim(
                        u8,
                        title_line[idx + title_prefix.len ..],
                        " \t",
                    );
                } else break :title null;
            } orelse null;

            const body = body: {
                const body_section = std.mem.trimStart(u8, lines.rest(), " \n\t");

                if (!std.ascii.startsWithIgnoreCase(body_section, body_prefix)) break :body null;

                break :body std.mem.trim(
                    u8,
                    body_section[body_prefix.len..],
                    " \t",
                );
            } orelse null;

            return .{
                .title = if (title) |t| a.dupe(u8, t) catch @panic("OOM") else null,
                .body = if (body) |b| a.dupe(u8, b) catch @panic("OOM") else null,
            };
        }
    };

    pub const OrderEntry = struct {
        filename: []u8,
        text: ?[]u8,

        pub fn deinit(self: *OrderEntry, a: std.mem.Allocator) void {
            a.free(self.filename);
            if (self.text) |text| a.free(text);
        }

        pub fn parseArray(
            a: std.mem.Allocator,
            input: []const u8,
        ) ![]@This() {
            var lines = std.mem.splitScalar(u8, input, '\n');

            var list = try std.ArrayList(@This()).initCapacity(a, 16);
            while (lines.next()) |line_raw| {
                const line = std.mem.trim(u8, line_raw, " \t\r");
                if (line.len == 0) continue;

                var split = std.mem.splitScalar(u8, line, '-');
                const split_first = split.first();
                if (split.peek() != null) {
                    try list.append(a, @This(){
                        .filename = try a.dupe(u8, std.mem.trim(u8, split_first, " \t")),
                        .text = try a.dupe(u8, std.mem.trim(u8, split.rest(), " \t")),
                    });
                } else try list.append(a, @This(){
                    .filename = try a.dupe(u8, line),
                    .text = null,
                });
            }

            return try list.toOwnedSlice(a);
        }
    };
};

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

    const list = try CollectionTemplate.OrderEntry.parseArray(
        std.testing.allocator,
        input,
    );
    defer {
        for (list) |*v|
            v.deinit(std.testing.allocator);
        std.testing.allocator.free(list);
    }

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
        \\Title: Title!
        \\ Body: Body text
        \\is long
        \\and multiple lines
    ;

    var info = CollectionTemplate.Info.parse(std.testing.allocator, input);
    defer info.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(
        "Title!",
        info.title.?,
    );

    try std.testing.expectEqualStrings(
        \\Body text
        \\is long
        \\and multiple lines
    ,
        info.body.?,
    );

    std.debug.print(
        \\Test success!
        \\
    , .{});
}

test "plexe" {
    var plexe = ImageCategory.Plexe([]const u8, &"default"){};
    plexe.plexe.unpublished = "unpublished";
    plexe.plexe.sketch = "sketch";
    plexe.plexe.editorial = "editorial";
    plexe.plexe.portraits = "portraits";
}
