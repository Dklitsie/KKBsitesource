# Source Code Tour Pt.1
> A tour of the build system 

Today I figured I would start the tour of the source code of this site with the primary building block of the application: `build.zig`.

## `build.zig`
My build is pretty standard, so I'm not going to share the whole file, instead I will just share the out of the ordinary steps.
The first is a function I wrote that sources from a `.env` file, and the other is a combination of a tool and a few lines that expose a `.json` file to my program.

### `.env` Sourcing
`.env` files are usually hidden from version control and store configuration values such as API keys or secrets. When loaded, the values become environment variables that only the running process and its child processes can access at runtime.
Before, I was using [`zdotenv`](https://github.com/BitlyTwiser/zdotenv), but I've been trying to minimize dependencies and I though it would be fun to try to source an `.env` file at comptime. 
#### The code
```zig
fn loadDotEnv(run: *std.Build.Step.Run) void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var env_file = std.fs.cwd().openFile(".env", .{}) catch |e| {
            switch (e) {
                error.FileNotFound => {
                    log.info(
                        \\ No .env file found
                    , .{});
                },
                else => {
                    log.err(
                        \\ build.zig could not open .env file: {any}
                    , .{e});
                },
            }
            return;
    };

    defer env_file.close();

    const read_buffer = arena.alloc(u8, 2048) catch @panic("out of memory");
    var reader = env_file.reader(read_buffer);

    const contents = reader.interface.allocRemaining(arena, .unlimited) catch @panic("failed to read");

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            var parts = std.mem.splitScalar(u8, trimmed, '=');

            const key = parts.first();
            const value = std.mem.trim(u8, parts.rest(), " \"");

            run.setEnvironmentVariable(key, value);
    }
}

```
The function is pretty simple: given a `Run` step, it checks for an `.env` file. If one exists, it parses the file and sets environment variables specifically for that `Run` step. This way the environment variables can be accessed by the executed program exactly as they would be if any other `.env` library was used.
### Blog post metadata
Notice the section at the top of this page that tells you when this post was last edited? That was trickier to implement than you would think. It's easy enough to access that information in my local environment, but this website is hosted remotely. That requires that I copy the source code of this website into a docker container. When the files are copied the last modified time of the copies is simply the time that they were copied. If I hadn't implemented this step, every blog post would always have the same last modified time.
 Basically, I've written an executable that reads the `blogs` directory and creates a `JSON` map of all the blog posts and their *true* last updated time. Then, when I parse through my blog posts to actually present them I reference the generated `JSON` file to get the true last updated time, rather than the blog post's file's last updated time. This executable is run everytime I make a git commit that includes changes to the blog directory. That way, I don't have to remember to actually run the executable.
### The code
```zig
pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cwd = std.fs.cwd();
    var dir = try cwd.openDir(BLOG_DIR, .{ .iterate = true });
    var it = dir.iterate();

    var files = try std.ArrayList(Metadata).initCapacity(arena, 2048);

    while (try it.next()) |entry| {
            if (entry.kind != .file) continue;
            if (entry.name[0] == '.') continue;

            const stat = try dir.statFile(entry.name);
            log.warn("{s} : {d}\n", .{ entry.name, stat.mtime });
            try files.append(arena, Metadata{
                .path = entry.name,
                .last_modified = @as(i64, @intCast(stat.mtime)),
            });
    }
    var out: std.io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(files.items, .{ .whitespace = .indent_2 }, &out.writer);

    const json_bytes = out.toOwnedSlice() catch @panic("out of memory");

    const outfile = "blogsMetadata.json";
    var file = try std.fs.cwd().createFile(outfile, .{});
    const realpath = try std.fs.cwd().realpathAlloc(arena, outfile);
    log.warn(
            \\ Writing to file: {s}
    , .{realpath});
    defer file.close();
    try file.writeAll(json_bytes);
}
```
And then in my main `build.zig` file, I've exposed the generated `blogsMetadata.json` file to my program in this single line: 
```zig
exe.root_module.addAnonymousImport("blogsMetadata.json", .{ .root_source_file = b.path("blogsMetadata.json") });
```
Now accessing the content of this file is as easy as calling
```zig
@embedFile("blogsMetadata.json")
```
It may seem like overkill, and maybe it is but I personally really like having the dates for my blog posts. Sure this whole ordeal increases the complexity of the site itself, but it contributes to my experience as the administrator. Updating blog posts is as simple as changing the contents of a `.md` file. The site takes care of the rest.

 Thanks for reading this post, next week I plan on going over the frontend.
