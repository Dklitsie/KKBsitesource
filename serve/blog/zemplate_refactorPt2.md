# Zemplate Type Graph Refactor

In my last post I went over how I've refactored `zemplate`'s parser to construct an AST rather than render directly from a token stream. This week I'm going to give an overview of how type introspection now works post-refactor. The old approach worked, but it had some serious problems—particularly with how it handled nested structs, which caused the type representations to balloon quickly. This new solution is much more elegant and scales way better.

### How is introspection used?
A `Template` is a type returned by the `Template` function, which simply returns a small wrapper around any type. 
For example, if I have a struct:

```zig
const MyStruct = struct {
  string: []const u8,
  nested: Nested,
};

const Nested = struct {
    number: u32,
};

```
I would initialize a `Template` for that struct like so: 
```zig
Template(MyStruct).init(
  allocator,
  .{
    .string = "World",
    .nested = .{ .number = 42 },
  },
);
```
**Introspection** is how I'm able to access the fields of this template struct at runtime. For example, I might have a template text:
```
Hello {|.string|}!
The meaning of life is {|.nested.number|}
```
And I would expect the output:
```
Hello World!
The meaning of life is 42
```

### The old approach

I have a [previous post](https://www.voidkandy.space/Blog?post=zemplate-gets-control-flow) where I discuss the way I used to do type introspection. I'm not going to rehash all the details here—partly because I've already covered it, but also because the implementation was complex enough that I've honestly forgotten some of the finer details.

The big problem with that solution was that it required constructing a type to encapsulate all the possible types that might be returned from accessing a struct. This would very quickly balloon, especially when dealing with nested structs. The new solution avoids this entirely.

### Scoping vs. Accessing

The first thing I had to figure out was what accessing a field actually *does* in different contexts. I found there are really only two use cases: **entering a new scope** or **accessing and writing** the field.

Entering a scope happens when an if or for block is entered, for example:

```
||zz for .string zz||
||zz endfor zz||
```

Accessing is what you saw in the first example—the contents of a field actually need to be rendered to the result of the template.

Since I managed to boil my needs down to these two things, I can encapsulate each in a function signature.

`GetInnerScope` functions take some `Scope` and return another `Scope`:

```zig
const GetInnerScopeFunc = *const fn (
    Allocator,
    Scope,
) error{ OutOfMemory, NotPresent }!Scope;
```

`WriteAccessFunc` takes some scope, a writer, and some options associated with writing that type, then writes to the writer, returning `void` on success or some `Error` otherwise:

```zig
const WriteAccessFunc = *const fn (
    *std.Io.Writer,
    Scope,
    std.json.Stringify.Options,
    bool,
) (util.WriteError || error{NotPresent})!void;
```

### What is a `Scope`?

Before moving forward, I should clarify what exactly a `Scope` struct is. This struct is the cornerstone of the refactor. Here are the relevant fields and init signature (I've omitted some implementation details):

```zig
const Scope = struct {
  instance: *const anyopaque,
  access_map: std.StaticStringMap(WriteAccessFunc),
  child_scopes: std.StaticStringMap(GetInnerScopeFunc),
  createIteratorFunc: ?*const fn (@This()) Iterator,
  pub fn init(val: anytype, a: Allocator) error{OutOfMemory}!@This() {}
};
```

Here's the purpose of each field:

+ **instance** - An opaque pointer to whatever type the `Scope` was initialized with.
+ **access_map** - A map of functions for writing each field and subfield of the type `Scope` was initialized with. This is constructed at comptime and passed to `Scope` upon initialization.
+ **child_scopes** - A map of functions for entering a scope for each field and subfield of the type `Scope` was initialized with. Also constructed at comptime.
+ **createIteratorFunc** - A function that returns an `Iterator` object. Some scopes aren't iterable (for example, a `Scope` with root type `u32`), which is why this field is optional.

### How are the maps constructed?

The entries of both `access_map` and `child_scopes` are computed at comptime. The maps are constructed from these pre-computed entries when a `Scope` object is created. The way this works is pretty sweet.

The basic problem is that a `Scope` can be created for virtually any type. So, a function chain needs to be constructed for accessing child scopes and instances for writing. I'm not going to share all the gritty details of how these entries are constructed...if you *really* must know you can check out the [source code](https://github.com/voidKandy/zemplate/blob/dev/src/Scope.zig). What I will share is the 'secret sauce' of how I am able to access *any* nested field of a give root type.
```zig
inline fn buildInstanceWalkerChainItem(
    comptime T: type,
    comptime fieldname: []const u8,
) WalkToInstanceFunc {
    return &struct {
        fn call(inst: *const anyopaque) error{NotPresent}!*const anyopaque {
            log.debug(
                \\ Dereferencing ptr: {any} as {s}
            , .{ inst, @typeName(T) });
            if (!@hasField(T, fieldname)) return error.NotPresent;
            return @ptrCast(&@field(@as(*const T, @ptrCast(@alignCast(inst))), fieldname));
        }
    }.call;
}

inline fn buildInstanceWalkerFunctionChain(
    comptime Root: type,
    comptime basename: []const u8,
) [util.countPeriods(basename)]WalkToInstanceFunc {
    // a comptime function that splits some basename such as '.field.nested.number' into an array of those field names ['field', 'nested', 'number'] 
    const fields = comptime basenameToFields(basename); 
    comptime var funcs: [util.countPeriods(basename)]WalkToInstanceFunc = undefined;

    comptime var Ty: type = Root;
    inline for (fields, 0..) |name, i| {
        funcs[i] = buildInstanceWalkerChainItem(Ty, name);
        Ty = @FieldType(Ty, name);
    }
    return funcs;
}
```
To illustrate how this pair of functions works, consider a `Scope` initialized with a `MyStruct` instance. When the `Scope` is constructed, the instance is coerced into an `*const anyopaque`. If I want to access the `number` field of the `nested` field, I can call `buildInstanceWalkerFunctionChain(MyStruct, ".nested.number")`. This will return a function chain that knows how to navigate to the `number` field of the `nested` field by progressing through the type graph. This is a great way to either write that field if I need to write it to the template, or construct a new `Scope` from that field, if I need to open a for loop or something.

### Wrapping up
The core idea here is that instead of trying to build a type that represents every possible value that could be accessed, I'm building function chains at compile time that know how to navigate to any field in the type graph. Each `Scope` carries these pre-computed maps of accessor functions, which means at runtime I just look up the right function and call it. It's cleaner, scales better with nested types, and honestly just makes more sense conceptually.
