# Post Zero
> I've finally found the time to finish the blog feature of this site :D

After breaking my wrist skateboarding and getting laid off, I finally have the time to program again, albeit _very_ slowly on account of the broken wrist. I plan on doing blog posts going over the architecture of this site in the coming weeks and I though the blog feature would be a great place to start.

### Code Blocks and Syntax Hilighting
I'm happy to say I can include code blocks with syntax hilighting, here are a few examples:

##### Zig
```zig
const std = @import("std");
fn greet(name: []const u8) void {
  std.debug.print("Hello {s}!", name)
}

greet("World");
```

##### Rust
```rust
fn greet(name: &str) {
    println!("Hello, {}!", name);
}

greet("World");
```

##### Javascript
```javascript
function greet(name) {
  console.log(`Hello, ${name}!`);
}
greet("World");

```

### Images
I can also embed images into my posts, here is one my wife took this summer when we went up to Pyramid Lake with some friends:
![pyramid lake](imgs/pyramid-lake.png)
Isn't she talented :)

### In Closing
On my previous site, I had all my blog posts living in a postgres instance and all the images in an S3 bucket. Anytime I wanted to update anything it was a huge hassle. It's very likely this was just a skill issue. Either way, now I don't have to deal with any of that. The best part about the way I've written my blog is that everything lives as files on the server serving the site; no database, no S3, just a simple file system. This follows my simplicity first approach to building this site, which you will see more of as I post more. 

