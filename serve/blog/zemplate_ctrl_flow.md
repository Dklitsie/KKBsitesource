# Zemplate Gets Control Flow
I recently added support for for loops to [zemplate](https://github.com/voidKandy/zemplate), which required major changes throughout the library. This included significant internal restructuring, reorganization, and updates to core behaviors. I’ll focus mainly on the changes to how the library works rather than the general refactors.

### How a templating library works
Before diving into the redesign, it’s worth outlining the fundamental role of a templating library. A template defines a structured output (HTML, email bodies, etc.), and the library renders it by binding data into that structure. Some templating systems also allow limited logic or control flow within the template itself.
In a way, a templating library can be best thought of as a kind of compiler, the key difference being that instead of ouputting machine code, a templating "compiler" outputs a string.
##### **Traditional Compiler:**
`source code` > `tokenizer` > `parser` > `machine code`
##### **Template Compiler:**
`template text` > `tokenizer` > `parser` > `transformed output text`

## Changes to Tokens
### **Before**
The original version of zemplate had a pretty limited amount of tokens, they were:
```zig
pub const TokenType = enum {
    Block,
    MarkerOpen,
    MarkerClose,
    Access,
};
```
`MarkerOpen` and `MarkerClose` represented the "||zz" and "zz||" markers used to access fields on the data struct associated with a template. Everything between them became an `Access` token, and everything else (literal text, potentially spanning multiple lines) was emitted as a single `Block` token.
  
This design doesn’t really match how a typical compiler tokenizes input. In most compilers, tokens correspond to very small units (identifiers, operators, punctuation), and whitespace or punctuation usually splits tokens. My approach of stuffing arbitrary chunks of text into a single `Block` token was a shortcut I took to get the first working version of the library out the door. It worked, but it clearly wasn’t scalable.
  
From the beginning, I knew this choice would eventually force a major refactor once I wanted the library to support more complex features. And it did.
  
One particularly ugly part of the old design was the way I handled the markers: I had static `MARKER_OPEN` and `MARKER_CLOSE` variables holding the literal strings "||zz" and "zz||". This worked for the original feature set, but it was rigid and unextendable; definitely not something that could survive future expansion.

### **After**
After the work I've done, here is the new `Token.Type` enum:
```zig
pub const Type = enum {
    space,
    tab,
    newline,
    literal,
    access,
    marker_open,
    marker_close,
    expression_open,
    expression_close,
    for_open,
    for_close,
    json,
}
```
This structure is much closer to how traditional compilers tokenize input, and it also aligns better with Zig’s naming conventions. (When I first wrote zemplate, I was coming from Rust, so my naming habits reflected that.) Tokens are now split into smaller, more precise units.

The `marker_open`, `marker_close`, and `access` tokens behave mostly the same as before. Here’s what the newer or renamed tokens represent:

- `space`, `tab`, `newline` — Whitespace characters.
- `literal` — This replaces the old `Block` token. It represents any raw text that the templating engine should treat as a plain string with no semantic meaning.
- `expression_open`, `expression_close` — Because for loops needed a way to access data inside an iteration, I added a second type of wrapper. These correspond to `{{` and `}}`, similar to [gomplate](https://docs.gomplate.ca/syntax/). They allow expressions inside loop contexts without conflicting with the main marker syntax.
- `for_open`, `for_close` — Tokens for `for` and `endfor`, only valid inside `marker_open` / `marker_close`. These make loop boundaries explicit during lexing.
- `json` — Used to modify how an `access` token is interpreted. When a `json` token follows an access, it tells zemplate to serialize the accessed field as JSON.

## Changes to parser
Since I have arbitrary data associated with each template, I needed to leverage zig's **comptime** in some fun ways. The cornerstone to this is a function that takes some data and outputs a `type`.
### **Before**
Here is the `Template` function before:
```zig
pub fn Template(
    comptime Context: type,
    TemplateString: []const u8,
) type {
    const ContextInfo = @typeInfo(Context);
    return struct {
        const Self = @This();
        context: Context,
        allocator: std.mem.Allocator,

        const Error = error{};

        pub fn init(ctx: Context, allocator: std.mem.Allocator) !Self {
            return .{
                .context = ctx,
                .allocator = allocator,
            };
        }

        pub fn render(self: *Self) !ArrayList(u8) {
            var buffer = try ArrayList(u8).initCapacity(self.allocator, 1024 * 1024);
            var lexer = Lexer.init(TemplateString[0..]);
            try lexer.processInput(self.allocator);

            var current_node: ?*std.DoublyLinkedList.Node = &lexer.head.?.node;

            while (current_node) |n| {
                const t: *parse.Token = @fieldParentPtr("node", n);
                defer self.allocator.destroy(t);
                defer t.*.deinit(self.allocator);
                switch (t.typ) {
                    TokenType.Block => {
                        try buffer.appendSlice(self.allocator, t.content);
                    },
                    TokenType.Access => {
                        const lookup = std.mem.trim(u8, t.content, "\n .");

                        inline for (ContextInfo.@"struct".fields) |f| {
                            if (std.mem.eql(u8, f.name, lookup)) {
                                const val = try access_field(f.name, Context, self.allocator, self.context);
                                defer self.allocator.free(val);

                                try buffer.appendSlice(self.allocator, val);
                            }
                        }
                    },
                    else => {},
                }
                current_node = t.node.next;
            }
            return buffer;
        }
    };
}
```
Pretty straightforward: since `MarkerOpen` and `MarkerClose` were only relevant during lexing, the parser only needed to handle `Block` and `Access` tokens. For a `Block` token, the parser simply appended its contents to the output buffer. For an `Access` token, it looked up the corresponding field in the `Context` struct based on the token’s content.

The `access_field` function (not shown) essentially checked whether the field was “stringy”: in Zig, either `[]u8`, `[]const u8`, or `ArrayList(u8)`, if so, appended it to the buffer.

As a side note, the inline iteration over Context’s fields is necessary because accessing a field by name in Zig requires a comptime string; iterating inline provides an easy way to get that. It’s admittedly brittle, but, like other parts of the original implementation, it was sufficient for my initial needs.

### **After**
The `Template` function has ballooned significantly to accomodate the increased complexity of the library. Instead of sharing the whole function I'm going to go through block-by-block.
The new signature of the function is:
```zig
pub fn Template(comptime Context: type) type
```
There was realistically no reason for the template string to be a function argument, so now all it takes is the `Context` type.

Having iteration in Templates adds few complications:
* how do we iterate through a given field of `Context`?
* what if the field isn't iterable?
* how do we keep the rendering fast?

The first section of the `Template` function addresses these:

##### **Identifying Iterable Fields**
First we need to check how mnay iterable fields our `Context` struct actually has, while we're at it we also check that `Context` is in fact a `struct`:
```zig
const context_type_info = @typeInfo(Context);
const AMT_ITERABLE_FIELDS = blk: switch (context_type_info) {
    .@"struct" => |s| {
        var amt_cannot: usize = 0;
        inline for (s.fields) |f| {
            if (root.iterate.UnwrapIterableChild(f.type) == null) amt_cannot += 1;
        }
        break :blk s.fields.len - amt_cannot;
    },
    else => @compileError("Cannot create template from " ++ @typeName(Context)),
};
```
`UnwrapIterableChild` checks whether a type is iterable, returning the item type produced by each call to `next`. It works recursively, dereferencing pointers until it reaches a “base type.” For example, `UnwrapIterableChild([]const u8)` would return `u8`.

Next, we populate an array of `StructField` objects for the fields that are actually iterable:
```zig
const iterable_fields_arr: [AMT_ITERABLE_FIELDS]Type.StructField = blk: {
    var tmp: [AMT_ITERABLE_FIELDS]Type.StructField = undefined;
    var i: usize = 0;
    inline for (context_type_info.@"struct".fields) |f| {
        if (root.iterate.unwrapIterableChild(f.type) != null) {
            tmp[i] = f;
            i += 1;
        }
    }
    break :blk tmp;
};
```
##### **Defining Union and Enum types for iteration**
We need a type that can represent any value returned when iterating over a struct’s fields. For example, given:
```zig
struct {
  number: u32,
  names: []const []const u8,
  datas: []const Data,
}
```
We cannot iterate through the `number` field since it stores a single `u32`. But, we can iterate through `names` and `datas`. So, we would need a union type that would look something like:
```zig
union (enum) {
  names: []const u8,
  datas: Data,
}
```
This allows a generic next method to return an enum that can then be accessed via the `@field` builtin.

So, we construct a corresponding `enum` and `union`:
```zig

const meta_fields: struct {
    un_fields: [AMT_ITERABLE_FIELDS]Type.UnionField,
    en_fields: [AMT_ITERABLE_FIELDS]Type.EnumField,
} = blk: {
    var ufields: [AMT_ITERABLE_FIELDS]Type.UnionField = undefined;
    var efields: [AMT_ITERABLE_FIELDS]Type.EnumField = undefined;

    inline for (iterable_fields_arr, &ufields, &efields, 0..) |iter_fld, *unfld, *enfld, j| {
        const Typ = root.iterate.UnwrapIterableChild(iter_fld.type).?;
        unfld.* = Type.UnionField{
            .alignment = @alignOf(Typ),
            .name = iter_fld.name,
            .type = Typ,
        };
        enfld.* = Type.EnumField{
            .value = j,
            .name = iter_fld.name,
        };
    }
    break :blk .{ .un_fields = ufields, .en_fields = efields };
};

const Tag =
    @Type(Type{
        .@"enum" = .{
            .fields = &meta_fields.en_fields,
            .tag_type = u32,
            .decls = &[_]Type.Declaration{},
            .is_exhaustive = true,
        },
    });
const Union =
    @Type(Type{
        .@"union" = .{
            .fields = &meta_fields.un_fields,
            .decls = &[_]Type.Declaration{},
            .tag_type = Tag,
            .layout = .auto,
        },
    });
```

##### **Defining Iterator types**
Now that we've defined the shape of the possible return values when attempting to iterate through a struct's field, we will define types for _creating_ and _destroying_ as well as getting the _next_ value in a field iterator:

```zig
const CreateFieldIterFunc = *const fn (std.mem.Allocator, *Context) *anyopaque;
const DestroyFieldIterFunc = *const fn (std.mem.Allocator, *anyopaque) void;
const NextItemFunc = *const fn (*anyopaque) ?Union;
const IteratorWrapper = struct {
    createFunc: CreateFieldIterFunc,
    destroyFunc: DestroyFieldIterFunc,
    nextFunc: NextItemFunc,
};
```
Notice that `NextItemFunc` returns the `Union` that we defined earlier.


##### **Mapping Fields to Iterators**
Finally, we create a map from field names to `IteratorWrapper`s. The function `StructFieldIterator` generates a type-specific iterator for each field. We wrap its concrete-typed methods so they work with `*anyopaque`:
```zig
var iterator_wrapper_arr: [AMT_ITERABLE_FIELDS]struct {
    []const u8,
    IteratorWrapper,
} = undefined;

inline for (iterable_fields_arr, &iteriator_wrapper_arr) |f, *item| {
    item.*.@"0" = f.name;
    const T = root.iterate.StructFieldIterator(Context, f.name);

    const createFn = struct {
        fn fromParentWrapper(a: std.mem.Allocator, parent: *Context) *anyopaque {
            const instance = a.create(T) catch @panic("out of memory");
            instance.* = T.fromParentPtr(parent);
            const opaq: *anyopaque = @ptrCast(instance);
            return opaq;
        }
    }.fromParentWrapper;
    const destroyFn = struct {
        fn destroy(a: std.mem.Allocator, inst: *anyopaque) void {
            const instance: *T = @ptrCast(@alignCast(inst));
            a.destroy(instance);
        }
    }.destroy;
    const nextFn = struct {
        fn nextWrapper(inst: *anyopaque) ?Union {
            var instance: *T = @ptrCast(@alignCast(inst));
            const next = instance.next() orelse return null;
            return @unionInit(Union, f.name, next);
        }
    }.nextWrapper;
    item.@"1" = IteratorWrapper{
        .createFunc = createFn,
        .destroyFunc = destroyFn,
        .nextFunc = nextFn,
    };
}

const create_iterator_function_map = std.StaticStringMap(IteratorWrapper).initComptime(iterator_wrapper_arr);
```

##### **Iterating in parser**
Once all this is defined, it makes iterating actually kind-of trivial:
1. Encounter `for_open` token
2. take tokens until encountering an `access`
3. lookup an `IteratorWrapper` from the `literal` field of the `access` token
4. If one exists, create the iterator, defer its destruction, and iterate using a while loop. Use `@field` on the returned Union to access the concrete item type.

On top of the simplicity of iteration and the state management that goes with that, this handles the questions we asked before quite well:
* how do we iterate through a given field of `Context`? - we create an iterator for the field when a `for_open` token is encountered. That iterator manages it's own state.
* what if the field isn't iterable? - A non-iterable field will only be accessed if the template is invalid. In that case, we return a `SyntaxInvalid` error and log it appropriately so the user knows what to fix. 
* how do we keep the rendering fast? - Because all iteration setup is done at comptime, retrieving an iterator for a given field has O(1) time complexity. 

#### New `render` Signature
I won’t go into the full logic of the `render` function here, but since the `template_string` argument was removed from `Template`, it’s now passed directly to `render`. Additionally, a new argument allows users to specify how `access` tokens marked with `json` should be serialized:
```zig
pub fn render(self: *Self, a: std.mem.Allocator, template_string: []const u8, json_opts: std.json.Stringify.Options) Error![]u8 
```

## Conclusion
I went through several iterations before landing on this solution, ultimately leveraging _comptime_ to effectively memoize the fields that can be iterated. I’m really happy with how far the library has come.

There’s still more work to do. Eventually I plan to add support for if statements, likely using a very similar approach.

Thanks for reading :) 
