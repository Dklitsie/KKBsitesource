const std = @import("std");
const log = std.log.scoped(.BUILD);

const PAGES_DIR = "pages";

pub fn embedPages(b: *std.Build, exe: *std.Build.Step.Compile) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cwd = std.fs.cwd();
    var dir = try cwd.openDir(PAGES_DIR, .{ .iterate = true });
    var it = dir.iterate();

    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (entry.name[0] == '.') continue;
        exe.root_module.addAnonymousImport(entry.name, .{ .root_source_file = b.path(try std.fmt.allocPrint(arena, "{s}/{s}", .{ PAGES_DIR, entry.name })) });
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zemplate = b.dependency("zemplate", .{});
    const zyph = b.dependency("zyph", .{});

    // Executable used by github actions to dynamically create blogs metadata

    const read_blog_data_module = b.createModule(.{
        .root_source_file = b.path("tools/read_blog_posts_metadata.zig"),
        .target = target,
        .optimize = optimize,
    });
    {
        const exe = b.addExecutable(.{
            .name = "read_blog_posts_metadata",
            .root_module = read_blog_data_module,
        });
        b.installArtifact(exe);
        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        const run_step = b.step("metadata", "get blogs metadata");
        run_step.dependOn(&run_cmd.step);
    }

    const exe = b.addExecutable(.{
        .name = "zortfolio",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.root_module.addImport("blog_metadata", read_blog_data_module);
    exe.root_module.addImport("zemplate", zemplate.module("zemplate"));
    exe.root_module.addImport("zyph", zyph.module("zyph"));

    embedPages(b, exe) catch @panic("failed to embed pages");
    exe.root_module.addAnonymousImport("blogsMetadata.json", .{ .root_source_file = b.path("blogsMetadata.json") });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    @import("btzdotenv").loadDotEnv(run_cmd);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .name = "test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe_unit_tests.root_module.addImport("zemplate", zemplate.module("zemplate"));
    exe_unit_tests.root_module.addImport("zyph", zyph.module("zyph"));

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
