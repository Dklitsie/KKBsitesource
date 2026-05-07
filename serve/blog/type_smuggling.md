# Smuggling Types Through Function Pointers
If you've been keeping up, you're aware that I recently did a massive refactor of my templating engine, [zemplate](https://github.com/voidKandy/zemplate). My last post covered the `Scope` struct that I utilized in order to create a recursive model for rendering statements in the templating language. 

In order to get `for` loops working, I needed to be able to create some *concrete* type I could pass around that would allow me to iterate over any arbitrary array or slice. I struggled a lot with this, but eventually came up with a solution that I'm quite happy with.

## The Problem
Implementing a truly generic iterator `type` is actually fairly easy. Typically, you’d do this by declaring a function `Iterator` that takes a `type` and returns a `type` with methods for managing iterator state. The issue with this approach is that the actual iterator `type` is different for every `type` you want to iterate over. Consider the following:
```zig
inline fn Iterator(comptime T: type) type {
    const ItemType = GetItemTypeOfIterable(T) orelse @panic("T NOT ITERABLE");
    return struct {
        instance: T,
        index: usize,
        pub fn next(self: *@This()) ?ItemType {
            /// implementation logic...
        }
    };
}

const StringIterator = Iterator([]const u8);
const NumListIterator = ([]const i32);
```
Here, `StringIterator` and `NumListIterator` are two completely distinct types. If I wanted to write a function that operated on an iterator, I’d have to make that function generic as well, something like this:
```zig
fn doSomethingWithIterator(iterator: anytype) void {
    // this check is necessary since `iterator` could be literally anything
    if (!@hasDecl(@TypeOf(iterator), "next")) @panic("iterator is not an Iterator type");

    while (iterator.next()) |item| {
        // do something with item
    }
}
```
This gets annoying quickly. Worse, if I wanted to store an iterator inside a struct, that would be impossible unless the struct itself was also generic.

### A Concrete Iterator
The way I solved this was by making the `Iterator` type concrete:
```zig
const Iterator = struct {
    base_ptr: *const anyopaque,
    stride: usize,
    index: usize,
    len: usize,
    pub fn next(self: *@This()) ?*const anyopaque {
        /// implementation logic...
    }
};
```
Now `Iterator` is a real, concrete type. I can use it as a struct field, pass it as a function argument, or store it anywhere else that requires a known type at compile time. The downside is that `next` no longer returns a concrete value, but instead a pointer to an opaque type.

To see why this is a problem, consider a revised version of `doSomethingWithIterator`:
```zig
fn doSomethingWithIterator(iterator: Iterator) void {
    // we no longer need to check for a `next` method
    while (iterator.next()) |item| {
        // we have no way to do anything with `item`,
        // since it could be a pointer to literally anything
    }
}
```
Notice, we now have the *concrete* type `Iterator` as a function parameter, however, `iterator.next` returns a pointer to an opaque type. This means we can't directly use the returned value in any meaningul way.
So how do we solve this?

If you think about it, what I actually need from an iterator isn’t type-specific access to the item, but a way to apply the same operation to each element in a collection. In my case, iterating means creating a scope for each item and rendering the statements inside a block.

With that in mind, what if we added one more field to the `Iterator` struct:
```zig
visitFunc: *const fn (
    Allocator,
    *const anyopaque,
    *const anyopaque,
    *anyopaque
) Error!void,
```
At first glance, three opaque pointers might look a little intimidating, but it’s actually pretty straightforward. The first pointer is the value returned by `next`, the second is a pointer to a function that takes the next item, and the last is a pointer to any additional arguments to that function. By making this a field of `Iterator` rather than a static method, we can have any function passed to as this `visitFunc` when we construct the `Iterator`. 
We had a correct intuitition that we had before, we want a function that takes a `type` at comptime, but not to return the iterator `type` itself, but instead a function to build a concrete iterator for a specific `type`. If we have the context of the `type` the iterator is derived from, than we have all that we need to cast the `*const anyopaque` into the `type` we know it should be and pass it to some other function that expects that type. 
```zig
const Iterator = struct {
    /// fields 
    inline fn Builder(comptime T: type) type {
        return struct {
            const ItemType = UnwrapIterableChild(T) orelse return error.NotIterable;
            const stride = @sizeOf(ItemType);
        
            const PointerInfo = struct {
                base_ptr: *const anyopaque,
                len: usize,
            };
            fn ptrInfo(ptr: *const anyopaque) PointerInfo {
                /// implementation logic... 
            }
            fn init(ptr: *const anyopaque) Iterator {
                const info = ptrInfo(ptr);
                return .{
                    /// if you're not familiar with zig, I'm taking a pointer to a function by declaring a method on an anonymous struct
                    .visitFunc = &struct {
                        fn visit(a: Allocator, item: *const anyopaque, f: *const anyopaque, args: *anyopaque) Error!void {
                            const v: *const ItemType = @ptrCast(@alignCast(item));
                            const scope = try Scope.init(v, a);
                            defer scope.deinit(a);
                            const func: *const fn (Scope, *anyopaque) Error!void = @ptrCast(@alignCast(f));
                            try func(scope, args);
                        }
                    /// notice the function reference
                    }.visit,
                    .base_ptr = info.base_ptr,
                    .len = info.len,
                    .stride = stride,
                };
            }
        };
    }
};
```
We're effectively tightening the type requirements on the function, we went from requiring a function typed as: 
```zig
fn(Allocator, *const anyopaque, *const anyopaque, *anyopaque) Error!void;
```
To a function that requires a function with the following: 
```zig
fn (Scope, *anyopaque) Error!void; 
```
Because visit is defined inside the scope of `Builder`, we get to “cheat” a little. Even though the iterator itself is concrete and type-agnostic, the visit function is generated with full comptime knowledge of `ItemType`. That means we can build an iterator at runtime that carries a function pointer which still knows exactly what type `base_ptr` points to.
The outermost `Iterator` also gets its own visit function: 
```zig
pub fn visit(
    self: @This(),
    a: Allocator,
    item: *const anyopaque,
    func: anytype,
    args: anytype,
) Error!void {
    return self.visitFunc(
        a,
        item,
        @ptrCast(func),
        @ptrCast(@constCast(args)),
    );
}
```
Let's say we've defined this function that we want to pass to each iterated item: 
```zig
/// we can conceivably make this any type,
/// but for demonstration this is an easy way to pass an empty struct to the visit function
const ArgType = @TypeOf(.{});

fn doSomethingForEach(scope: Scope, _: ArgType) Error!void {
    /// do something with scope
}
```

```zig
const base_string = "Hello World";
const iter = Iterator.Builder([]const u8).init(base_string);

while (iter.next()) |n| {
    try iter.visit(a, n, &doSomethingForEach, &.{});
}
```

Now we have an easy way to iterate over a string and do something with each character. In the library this is leveraged to create a new `Scope` per character and render any statements within a `for` block, but the same `Iterator` can be used for essentially any per-item operation.


### The `next` method 
Finally, it is worth stepping back and looking at how `next` works, since this is where pointer arithmetic comes into play:
```zig
pub fn next(self: *@This()) ?*const anyopaque {
    if (self.idx >= self.len) return null;
    const item_ptr: *const anyopaque = @ptrFromInt(@intFromPtr(self.base_ptr) + self.idx * self.stride);

    self.idx += 1;

    return item_ptr;
}
```
All we are doing here is advancing the base pointer by `stride * index` to compute the address of the next item. During initialization, we compute `len` and `base_ptr` by introspecting the type passed to `Builder`.

This logic is fairly straightforward. If the type is an array, we get the length directly from the array type and use the pointer passed as `base_ptr`, since arrays have a comptime-known size. If the type is a slice, we cast the value to a slice, read its `len` field at runtime, and use the slice’s `ptr` field to obtain a pointer to the first item, since slices store their length dynamically.
```zig
fn ptrInfo(ptr: *const anyopaque) PointerInfo {
    switch (type_info) {
        .array => |ar| {
            // iter.ptr points to the array itself
            return .{
                .base_ptr = ptr,
                .len = ar.len,
            };
        },
        .pointer => |p| {
            switch (p.size) {
                .slice => {
                    // iter.ptr points to SLICE STRUCT, not data
                    const slice: *const T = @ptrCast(@alignCast(ptr));
                    log.debug("ptrInfo: ptr={*}, slice.ptr={*}, slice.len={d}", .{ ptr, slice.ptr, slice.len });
                    return .{
                        .base_ptr = slice.ptr,
                        .len = slice.len,
                    };
                },
                else => {
                    @compileError(std.fmt.comptimePrint(
                        \\ No branch for pointer of size {s}
                    , .{@tagName(ptr.size)}));
                },
            }
        },
        else => {
            @compileError(std.fmt.comptimePrint(
                \\ No branch for {s}
            , .{@tagName(type_info)}));
        },
    }
}
```
### Considerations
Overall, I’m very happy with this solution. It’s already proven useful as a template for other pointer-heavy problems, and I can see myself applying the same pattern to things like handling `if` statements; for handling optional types, or booleans rather than iterables like arrays or slices.

That said, the implementation isn’t without tradeoffs. The most obvious one is that I’ve leaked a dependency on `Scope` into `Iterator`. The `visit` function generated by `Builder` assumes that each item will be used to construct a new `Scope`, which means this iterator isn’t fully general-purpose.

For this library, that’s an acceptable constraint. Every place I use this iterator, I do want to create a new `Scope`, so baking that assumption in simplifies the API. It also means I don’t need to thread an allocator through every `visit` call unless it’s explicitly part of the arguments.

If I ever needed this iterator to be more broadly reusable, that assumption would need to be lifted. For now, though, it’s a tradeoff I’m comfortable making.

Thanks for reading this week :)
