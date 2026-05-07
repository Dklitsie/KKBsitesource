# Zemplate AST Refactor
If you’ve been keeping up with my blog posts, you’ll know that `zemplate` didn’t start out in great shape. I cut corners, made tradeoffs I probably shouldn’t have, and wrote some genuinely questionable code. In fact, the original implementation didn’t even *really* have a proper `Token` type.

A little over a month ago, I refactored the tokenizer to use “real” token types. More recently, I’ve taken the next step and refactored the project again to use a “real” parser.
Before this refactor, the render pipeline for a `zemplate` template looked something like this:

```
[Input Text] -> [Tokens] -> [Rendered Text]
```
This worked, but because there was no intermediate structure between tokens and the final output, control-flow constructs were especially difficult to reason about.

After the refactor, the pipeline looks like this:
```
[Input Text] -> [Tokens] -> [Abstract Syntax Tree] -> [Rendered Text]
```
With the addition of an Abstract Syntax Tree (AST), it’s now much easier to reason about *how* rendering should be performed.

---

### What is an AST?
According to [Wikipedia](https://en.wikipedia.org/wiki/Abstract_syntax_tree):
> An abstract syntax tree (AST) is a data structure used in computer science to represent the structure of a program or code snippet. It is a tree representation of the abstract syntactic structure of text (often source code) written in a formal language. Each node of the tree denotes a construct occurring in the text.

In short, an AST allows us to encode the logic that the renderer walks through in order to render a template.

Previously, encountering a `.for_open` token would immediately trigger some rendering logic. Now, a `for` loop—and everything relevant to it—is parsed up front and represented as a data structure:

```zig
pub const ForStatement = struct {
    access: AccessExpression,
    block: BlockStatement,
    alternatives: ?[]ElseBlock,
};
```
This encapsulates a for loop in a very straightforward way:
+ access describes the field being iterated over
+ block represents the statements executed for each iteration
+ alternatives contains optional else blocks

Having this information structured explicitly makes the templating engine much easier to reason about and improve.

### Constraints
I want zemplate to be driven entirely by read-only access to Zig structs. Because of this, it makes sense to think of language statements as ways of driving that access, rather than as general-purpose programming constructs.
Features like mutable variables or arithmetic feel unnecessary for this goal, which makes let statements redundant and significantly narrows the scope of expressions.

### For Statements
`for` statements must iterate over a field of the outermost context struct. The AST itself has no knowledge of this context—it only represents syntax—so no validation is performed during parsing.

A `for` statement must include an AccessExpression, which is typically something like `.some_field`.

`AccessExpressions` can optionally be followed by tokens that alter how the field is accessed. For example: `.some_field json` will serialize the field into a JSON object. When used in a for statement, this causes the renderer to iterate over that JSON structure.

There is no support for iterating over arbitrary ranges.

### If Statements
`if` statement conditions can take several forms:
+ A comparison expression, such as `if .some_field > 3`
+ An optional typed field, which captures a payload: `if .some_optional`
+ A simple boolean field: `if .some_bool`

### Else Statements
`else` statements may either:
+ Be followed by an `if` condition (`else if`)
+ Stand alone as a catch-all branch
`else` blocks are valid for both `for` and `if` statements.

### Expressions
Expressions currently fall into one of three categories:
+ `Access`
+ `Comparison`
+ `Literal`
Literal expressions are only used in the context of comparisons and currently support string, integer, and boolean values.

## Whats next
As of writing this blog post I haven't actually gotten to write the layer between `[Abstract Syntax Tree] -> [Rendered Text]`, but I just finished getting all the needed tests passing for the AST. I wanted to wait until I had fully implemented the new refactor, but seeing as it's been just about a month since my last post, I wanted to get this out.
