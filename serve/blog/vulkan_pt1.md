# Journey into vulkan
Since September of 2025 I've been trying to learn Vulkan. I've learned a fair bit about the API, and I'd like to document the current state of my project. There are some fatal design flaws that I need to fix, but I want to use this post as an exercise in code explanation and as a way to solidify my understanding of the API and the abstractions I've built around it. Hopefully this helps me better understand how to move forward with the project.

## It began with a clone
Since I'm working in Zig, the first step was getting the vulkan C library working with Zig. Looking back, it's a fairly trivial task, but I had never done any C interop with zig at the time. I started by cloning [this repo](https://github.com/spanzeri/vkguide-zig). This repo showed me how to hook up arbitrary C libraries, to a zig project. Out of the box it comes with the C libraries `imgui`, `sdl3`, `stb`, `vma`, linked and wrapped. The Vulkan library is also wrapped, but it assumes that the user has a working Vulkan installation. It also included a great example of compiling shaders as a part of the build system and linking them to the project.

Once I had Vulkan installed on my Mac, there were a few build errors due to the version difference between the Zig used in the project and the Zig I had installed. After smoothing those over, all of the examples were working as expected.

The main module of the repo I cloned was `src/VulkanEngine.zig`. It was the only import into the main binary. So I began by creating my own `src/NewVulkanEngine.zig`, and imported that into main instead.

The main module of the repo I cloned was `src/VulkanEngine.zig`. It was the only import into the main binary. So I created my own `src/NewVulkanEngine.zig` and imported that into main instead. I then used NewVulkanEngine as the only module I would actually change while working through the [vulkan tutorial](https://vulkan-tutorial.com/). The rest of the repo served as a reference. Some things were done differently in the tutorial than in the repo. This was a little annoying, but honestly it was a great way to learn the Vulkan API and VMA.

> VMA is an allocation library for vulkan that makes memory management a little easier. It isn't used in vulkan tutorial, so being forced to port code from the tutorial to use the allocator in the repo was a great way to learn the vulkan API more thoroughly.


Eventually I ended up with a triangle rendered to the screen using only code I wrote. From there I continued through the tutorial until I had a compute shader for rendering the background and a depth buffer.

The next step was building the project in a way that made it easier to mutate. In this phase I made a lot of mistakes, but I also learned a lot. It’s also the phase I’m just now coming out of, with the intention of going back in and doing it again properly.

## The current state of the project
I’ll start with the build system, then move into the main binary, and finally explore the library code.

### `build.zig`
This file builds three libraries: `core`, `imgui` and `tools`. Imgui needs to built as it's own library so it can be linked to the core and used. Core is everything within the `src` directory. The tools library is a consumer of `core`; it is meant for creating things like camera systems, specific pipelines, and anything else that would require the consumption of the core library but shouldn't leak into core itself (this is one place that needs significant improvemenent).

Shaders are compiled and linked directly into the core library. This is actually really nice. Shaders can be written in an language that can compile to SPV format. The SPV files aren't actually built into the file system; instead, they are build artifacts that are embedded directly into the library itself.

Despite the fact that currently there is only one `main` binary file, the build system actually builds any `.zig` file in the `bins` folder. This is so I can eventually have multiple binaries for testing or any other reason. The binary is given access the `core` library and any tools in the `tools` folder.


### `main.zig` - the only current binary
Since it's a reasonable size, I'll just share the entire `main` function defined in `main.zig`: 
```zig
pub fn main() void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) @panic("Leaked memory");
    
    var api_version: u32 = undefined;
    _ = vk.EnumerateInstanceVersion(&api_version);
    var cwd_buff: [1024]u8 = undefined;
    const cwd = std.process.getCwd(cwd_buff[0..]) catch @panic("cwd_buff too small");
    var engine = core.VulkanEngine.init(
        gpa.allocator(),
        null,
        &initDescriptors,
        &initResources,
        &initPipelineObjects,
    );
    defer engine.deinit();

    engine.run();
}
```
You might notice that `VulkanEngine.init` takes 3 function pointers as initialization arguments:
```zig
pub fn init(
    a: std.mem.Allocator,
    alloc_cbs: ?*vk.AllocationCallbacks,
    createBoundDescriptorsFn: *const fn (*@This()) anyerror!std.StringHashMap(BoundDescriptor),
    createResourcesFn: *const fn (*@This()) anyerror!ResourceManager,
    createPipelineObjectsFn: *const fn (*@This()) anyerror!PipelineObjManager,
) VulkanEngine {
    // ...
}
```
> This is how I give control of pipelines, resources and descriptors to the consumer of the library. This is one of the fatal flaws with the current state of the project, but we'll get into that more later.


The rest of `main.zig` is just the declaration of these three functions (`initDescriptors`, `initResources`, `initPipelineObjects`) and some other helper functions that are broken out for readability and composability. 

As a first step into the library, let's dive into how each of these functions work and the objects they return.

### `BoundDescriptor`
My intention when creating this abstraction was to describe some data mapped to the GPU along with a function that runs every frame to update that data. I can also associate arbitrary CPU-side data with the struct if the per-frame function needs it.
```zig
data: root.vma_usage.AllocatedBuffer = .{ .buffer = null, .allocation = null },
mapped: ?*anyopaque = undefined,
descriptor_type: vk.DescriptorType,
descriptor_stage: vk.ShaderStageFlags,

updateFn: *const fn (@This(), root.VulkanEngine, *Self) void,
state_ptr: *anyopaque,
deinitStateFn: *const fn (*@This(), std.mem.Allocator) void,
```
If you read my [type smuggling](https://www.voidkandy.space/Blog?post=smuggling-types-through-function-pointers) article, this might look familiar. I use `state_ptr` to associate an arbitrary type with the concrete `BoundDescriptor` and construct functions at initialization time to coerce that pointer back to the proper type. I won’t go deeper here; if you’re confused, check out that post.

The rest of these fields have to do with Vulkan memory management and descriptors. 

Here is the `init` method signature: 
```zig
pub fn init(
    comptime T: type,
    comptime State: type,
    allocs: *root.VulkanEngine.Allocators,
    typ: vk.DescriptorType,
    stage_flags: vk.ShaderStageFlags,
    buffer_usage: vk.BufferUsageFlags,
    memory_usage: vma.MemoryUsage,
    state: State,
    comptime update: *const fn (*State, root.VulkanEngine, *Self) void,
) BoundDescriptor {
    // ...
}
```
Along with wrapping the the update function and constructing a `deinit` function, this also creates the `data` field by initializing a VMA buffer with the given `buffer_usage` and `memory_usage`, then mapping that memory to `mapped`. The provided `update` function can then mutate that mapped memory each frame.

The only current use of this abstraction is in the camera system. In `main`, it’s initialized like this:
```zig
const bound_camera = core.BoundDescriptor.init(
    tools.Camera.GPUData,
    tools.Camera,
    &engine.allocs,
    vk.DESCRIPTOR_TYPE_UNIFORM_BUFFER,
    vk.SHADER_STAGE_VERTEX_BIT,
    vk.BUFFER_USAGE_UNIFORM_BUFFER_BIT,
    c.vma.MEMORY_USAGE_CPU_TO_GPU,
    camera,
    &tools.Camera.control,
);
```
`Camera` lives in `tools` because it consumes `core` and should not ask anything of the engine itself. `Camera` has its own CPU-side state (passed as `State`), while `GPUData` contains what actually lives on the GPU:
```zig
pub const GPUData = struct {
    model: Mat4,
    view: Mat4,
    proj: Mat4,
};

near_plane: f32 = 0.1,
far_plane: f32 = 100.0,
fov: f32 = 45.0,

eye: Vec3 = DEFAULT_EYE,
target: Vec3 = DEFAULT_TARGET,
distance: f32 = DEFAULT_EYE.eucDist(DEFAULT_TARGET),

mode: Mode = .user_input,
```
The model, view and projection matrices all need to exist on the GPU because they are actually used by the shaders. The other fields are CPU-side configuration and update data. I won't share it because it's a little long, but the `control` method that exists on camera facilitates camera movement via user input by taking in the input state and mutating the `mapped` data accordingly.

### `ResourceManager`
The resource manager is just a struct with maps for resources: `mesh`, `texture`, `sampler`, `image`, `buffer`. The problem is that resources must eventually be uploaded to the GPU, which is why a function that creates a `ResourceManager` is passed to `VulkanEngine.init` rather than a manager itself. 

I’d like to move toward a manager that works in stages. One stage would convert file-system assets into intermediate CPU-side structures. Another would upload them to the GPU. That way the engine could simply be given a folder path at initialization and handle the rest.

### `PipelineObjManager`
The `PipelineObjManager` is just two hashmaps: 
```zig
const Type = enum { single, map };

pub const Entry = union(Type) {
    single: PipelineObject,
    map: std.StringHashMap(PipelineObject),
};

all_graphics: std.StringHashMap(Entry),
all_compute: std.StringHashMap(Entry),
```
This allows me to have `PipelineObject`s associated with either compute or graphics, this way I know where to call them. 

A `PipelineObject` looks like: 
```zig

const DrawImguiFunc = fn (*anyopaque) void;
const DrawFunc = fn (*anyopaque, DrawData, vk.CommandBuffer) void;
const DeinitFunc = fn (*anyopaque, *Allocators, vk.Device, ?*vk.AllocationCallbacks) void;
const InitFunc = fn (
    *anyopaque,
    *Allocators,
    InitData,
    []const ResourceManager.ResourceID,
    vki.LogicalDevice,
    ?*vk.AllocationCallbacks,
) anyerror!void;

drawFunc: *const DrawFunc,
drawImguiFunc: ?*const DrawImguiFunc,
initializeFunc: *const InitFunc,
cleanupFunc: *const DeinitFunc,
data_ptr: *anyopaque,
```
> I'm doing more type smuggling here.


Zig doesn’t have built-in interfaces, so I implemented my own via function pointers (a vtable). The `create` function populates that table by coercing `*anyopaque` back to `T` and calling its methods. This is unsafe. If I keep this abstraction, I’ll add comptime validation to ensure `T` conforms properly.

```zig
pub fn create(
    comptime T: type,
    allocator: Allocator,
) Allocator.Error!@This() {
    comptime validateT(T);
    const ptr = try allocator.create(T);
    ptr.* = T{};

    return .{
        .data_ptr = @ptrCast(ptr),
        .drawFunc = &struct {
            fn d(p: *anyopaque, dat: DrawData, cmd: vk.CommandBuffer) void {
                @as(*T, @ptrCast(@alignCast(p))).draw(dat, cmd);
            }
        }.d,
        .drawImguiFunc = if (@hasDecl(T, "drawImgui")) &struct {
            fn d(p: *anyopaque) void {
                @as(*T, @ptrCast(@alignCast(p))).drawImgui();
            }
        }.d else null,
        .initializeFunc = &struct {
            fn i(p: *anyopaque, allocs: *Allocators, idat: InitData, r: []const ResourceManager.ResourceID, logi: vki.LogicalDevice, cbs: ?*vk.AllocationCallbacks) anyerror!void {
                try @as(*T, @ptrCast(@alignCast(p))).init(allocs, idat, r, logi, cbs);
            }
        }.i,
        .cleanupFunc = &struct {
            fn c(p: *anyopaque, allocs: *Allocators, d: vk.Device, cbs: ?*vk.AllocationCallbacks) void {
                const pt: *T = @ptrCast(@alignCast(p));
                defer allocs.std.destroy(pt);
                pt.deinit(allocs, d, cbs);
            }
        }.c,
    };
}
```

The goal was to encapsulate everything about a pipeline into a single type defined in `tools`, keeping it out of the engine. In practice, this was a mistake. Pipelines *should* be baked into the engine. Letting consumers describe pipelines creates dependency cycles and ordering issues. I have to ensure meshes are inserted during `initResources`, then accessed later when the corresponding `PipelineObject` initializes. In short: a mess.

## Possible ways forward
As I've been saying throughout this post, many of these systems and the engine architecture are flawed, I don't know the solution to all issues, but I have some ideas.

### `PipelineObject`
As I said `PipelineObject` requires that pipelines be described by *consumers* of `core`, but I need to change that so pipelines are baked into the engine. A way forward for pipeline objects would look something like the following: 
1. Move the creation & declaration of pipelines into `core`
2. Expose them in a human readable by consumers (a `StringHashMap` comes to mind)
3. Replace `PipelineObject` with an abstraction that declares which pipeline(s) and datas it associates with
This introduces lifetime management issues for `PipelineLayout` and `Pipeline`. Layouts outlive pipelines. I’ll likely need some small manager for that. It shouldn’t be complex, but it needs to exist.

### `BoundDescriptor`
These currently require coordination between unrelated parts of the codebase. The data isn’t well encapsulated.
Worse: descriptor sets are only updated once at initialization. That’s incorrect. Descriptor sets often need to be updated between draw calls within a single frame. For example, if I bind a texture to a descriptor, I may need to update it between mesh draws rather than rebinding everything per asset. The current implementation ignores this entirely.
Like pipelines, descriptor sets and layouts probably need to be baked into `core`. Whatever replaces `BoundDescriptor` should declare which set and binding it uses. I’m still unsure how to move forward here, so this will likely be the last system I refactor.

### `ResourceManager`
The `ResourceManager` just needs to be change to manage the mapping of resources to the GPU. I mentioned this earlier but this will probably look like adding some kind of state management to the manager, likely via an enum, to control what the manager should do at certain points in the engine. I would like to remove the resource manager initialization function as a parameter to `VulkanEngine.init` and just have the engine take a `ResourceManager` object in its initial state constructed from some assets folder path.

## Conclusion
There is still *so* much work to be done, but I'm proud of where the project is at and I'm excited to move forward. Thank you for reading this post :)
