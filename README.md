# siggy

ABA-in-parsing-config format: the library should provide an API for
"supported" structs which can be used as a schema for parsing.

**Thesis.** A configuration is just a description of the shape of some Zig
data. Write the Zig type, get the parser. No separate schema language, no
codegen step, no runtime reflection tables: `siggy.parser(T)` builds a
type-specialized deserializer at compile time.

**Non-goals.** siggy is not a JSON superset, not a schema language, not
limited to Zig-only data shapes (though it is a Zig library), not a
codegen-first tool, and not an LSP-first tool.

```
index_threads_mask = { 0 1 range { start = 10 end = 12 } }
pin_threads_mask   = { 2, 3, 20, 21, }
```

## Schema = structure; ADTs only for `tagged` / `list[tagged]`

Ordinary configuration is structure: key/value pairs, nested blocks, and
lists of leaves. Abstract data types (unions) are needed only where the
format allows a *tagged block* (`range { ... }`) or where a list mixes
several shapes. Use a Zig union there and let the tag pick the variant.

## Grammar

```
TOKENS (EOF is produced by the lexer; the parser never sees a missing-token case)
  ASSIGN   '='
  START    '{'
  END      '}'
  COMMA    ','
  COMMENT  '#' … until end of line (skipped by the lexer, never emitted)
  LITERAL  all characters with ascii > 32, except '=', '{', '}', ',', '"', '#'
  QUOTED   '"' … '"', with JSON-style escapes \" and \\

GRAMMAR
document   = { assign } ;                                 // until END or EOF
assign     = LITERAL ASSIGN value ;
value      = LITERAL block                                // peek(1): LITERAL START
           | block
           | LITERAL
           | QUOTED ;
block      = START END                                    // peek(1): END → empty
           | START document END                           // peek(2): LITERAL ASSIGN
           | START list END ;                             // otherwise
list       = list_space | list_comma ;
list_space = list_item { list_item } ;                    // space only between elements
list_comma = list_item { COMMA list_item } [ COMMA ] ;    // comma only, optional trailing comma
list_item  = value ;
```

### Disambiguation

1. block: after START, peek one token.
   - END → empty.
   - otherwise peek two: LITERAL + ASSIGN → document; otherwise → list.
2. LITERAL vs LITERAL block in `value`: after LITERAL, peek one token.
   - START → Tagged{tag, block}; otherwise → Literal.
3. list mode: parse first list_item, then peek. COMMA → comma mode for the WHOLE
   list (allow trailing comma before END). Otherwise → space mode (COMMA anywhere
   is an error). Mode is fixed after the first item.
4. COMMA is never allowed inside document.
5. `10..12` is one LITERAL; the parser does not interpret `..`.
6. `{ }` is valid (empty). Its meaning (empty list / empty struct / invalid
   payload for a tag) is decided by the deserializer, not by the parser.

## Diagnostics

`ParsingError` is a flat error set covering lexing, parsing, and mapping:

| Phase | Codes |
|-------|-------|
| Lexing | `UnexpectedToken`, `UnterminatedQuote`, `InvalidEscape`, `NewlineInQuote`, `BomPresent`, `LiteralTooLong` |
| Parsing | `EmptyList`, `MixedListSeparators`, `CommaInDocument` |
| Mapping | `BadNumber`, `UnknownVariant`, `UnknownField`, `MissingField`, `DuplicateField`, `EmptyNotAllowed`, `UnsupportedShape`, `ExpectedQuoted`, `MaxDepthExceeded`, `MaxListLenExceeded` |
| Custom | `Custom`, `OutOfMemory` |

`Diagnostic` carries `code`, `offset` (byte offset into the source), and
`message`. A printer receives `*Diagnostics`, which adds `source` and `path`
so it can render context. Messages are short-lived scratch memory: they are
valid while the printer runs. `parser.diagnostic` keeps a copy of `code`,
`offset`, and `message` in the value allocator after the call.

`higgy` is the only renderer:

```
error[UnknownField]: examples/cpu.cfg:3:9: unknown field 'foo' in ram.CpuConfig
   3 | index_threads_mask = { foo }
     |                       ^^^
```

Custom printers get an out-parameter with the same shape and may use
`anyerror`; siggy ignores a printer's own errors but never loses the parse
error.

## Mapping rules

| AST node | Target type | Rule |
|----------|-------------|------|
| Literal | int/float/bool | leaf parser; `BadNumber` on failure |
| Literal | enum `E` | match variant name; `UnknownVariant` |
| Literal | `[]const u8` | **error**: strings must be Quoted |
| Quoted | `[]const u8` | decoded bytes, copied into the value allocator |
| Quoted | non-string | error (except a custom `decode`) |
| Block.document | struct `S` | field by field; unknown key → `UnknownField`; missing without default and not `?T` → `MissingField`; duplicate key → `DuplicateField` |
| Block.document | `std.AutoArrayHashMapUnmanaged(K, V)` | open dictionary: every assign is an entry; keys are literals decoded as `K` |
| Block.list | `[]T` | homogeneous: each item mapped as `T`; `MaxListLenExceeded` |
| Block.empty | `[]T` | empty list |
| Block.empty | struct `S` | every field must have a default or be `?T`; otherwise `MissingField` |
| Block.empty | `?T` | `null` |
| Block.empty | `union(enum)` | `EmptyNotAllowed` |
| Block.empty | other | `EmptyNotAllowed` |
| Tagged{tag, b} | `union(enum) U` | switch on the tag; recurse into the payload; `UnknownVariant` if absent |
| Tagged{tag, b} | other | `UnsupportedShape` |
| Literal(s) | `union(enum) U` | a `void` variant named `s` wins; else a non-void variant named `literal`; else `UnknownVariant` |

Strictness:

- `Literal` never deserializes into a string. `name = my-service` is an error;
  write `name = "my-service"`.
- Unknown keys and duplicate keys are errors. Missing keys need a default or
  `?T`.
- Lists are homogeneous by `T`, not by AST shape: `[]MaskItem` accepts a mix
  of `Literal` and `Tagged` because `MaskItem` covers both.
- `max_depth` and `max_list_len` are enforced during recursion.

A tagged payload that is a leaf accepts the `tag { value }` form
(`range { 10 }`), so `Color` inside a union can be written
`paint { red }` as well as `paint { }`-style empty blocks for `void`.

## Supported types (comptime)

`assertSupported(T)` in `src/siggy/support.zig` walks `T` and raises
`@compileError("unsupported type for siggy")` for the rest:

| Type | Notes |
|------|-------|
| `?T` | `T` supported; absent assign or `Block.empty` → `null`; implicit default `null` |
| `struct S` | every field type supported; fields without a default must be present |
| `[]T` | `T` supported |
| `union(enum) U` | every payload supported |
| `std.AutoArrayHashMapUnmanaged(K, V)` | `K` is a literal leaf (`[]const u8`, bool, integer, enum) |
| `bool`, `uXXX`, `iXXX`, `usize`, `isize`, `fXXX` | leaf parsers from Literal |
| `[]const u8` | only from Quoted |
| `enum E` | Literal → variant name |
| `T` with `pub decode` / `pub encode` | custom leaf |

## Custom types

```zig
pub fn decode(
    self: *Self,
    source_arena: std.mem.Allocator, // ephemeral: parse scratch, diagnostics
    value_arena: std.mem.Allocator,  // persistent: the decoded value itself
    node: siggy.AstNode,
    diag: *siggy.Diagnostic,
) anyerror!void;

pub fn encode(
    self: Self, // or *const Self; either receiver is accepted
    allocator: std.mem.Allocator,
) anyerror![]const u8;
```

- siggy allocates `Self` in the value arena with `value_arena.create(T)` and
  calls `decode` on the pointer. `decode` never allocates `Self` itself.
- `decode` must fill `diag` on semantic errors. If it returns an error without
  a message, siggy uses `error.Custom` plus `@errorName`.
- `encode` returns arena-owned bytes; the caller does not free.

## Two-arena contract

The lexer/parser layer takes two `*std.heap.ArenaAllocator`:

- `source_arena` owns the token slice, decoded QUOTED payloads, copies of
  every LITERAL used as a key, tag, or value, and diagnostic messages.
- `ast_arena` owns the AST nodes: `Document`, `Assign` arrays, `Block`, `Value`
  arrays, and `Tagged` wrappers.

Deinit is `ast_arena.deinit()` then `source_arena.deinit()`.

The schema layer takes two plain allocators instead, because it owns the
lifetimes itself:

- `source_allocator` (ephemeral) backs a scratch arena for the token slice,
  AST, and messages. siggy frees it before every `parse` returns.
- `dst_allocator` / `value_allocator` (persistent) owns the result: strings,
  slices, maps, custom values, and diagnostics. `source_arena` may be freed
  after deserializing; nothing in the value points into it.

## Example

`src/siggy/mask.zig` and `examples/cpu.cfg`:

```zig
pub const Range = struct { start: u32, end: u32 };

pub const MaskItem = union(enum) {
    literal: u32,
    range: Range,
};

pub const CpuConfig = struct {
    index_threads_mask: []const MaskItem,
    pin_threads_mask: []const MaskItem = &.{},
};

var parser: siggy.parser(CpuConfig) = undefined;
try parser.init(scratch_allocator, value_arena.allocator(), null);
const config = try parser.parse_file("examples/cpu.cfg");
```

## Public API

```zig
siggy.parser(T) type                  // the only function in root.zig
```

The returned type has:

```zig
pub fn init(self: *Self, source_allocator: Allocator, dst_allocator: Allocator, printer: ?Printer) !void
pub fn parse(self: *Self, text: []const u8) ParsingError!T
pub fn parse_file(self: *Self, path: []const u8) (ParsingError || FileIoError)!T
pub fn stringify(self: *Self, value: T) []const u8
```

Data types exported from `root.zig`: `ParsingError`, `FileIoError`,
`Diagnostic`, `Diagnostics`, `Printer`, `Options`, `AstNode`, `Token`,
`TokenKind`, and the `higgy` namespace (`higgy.Location`).

`higgy` (in `src/siggy/higgy.zig`) is the only renderer; there is no fmt/JSON
output in the MVP. `parse_file` reads through `std.Options.debug_io`, the same
I/O instance `std.debug` uses, with `Options.max_file_size` as the limit.

## What this is not

JSON superset, schema language, Zig-only format, codegen-first, LSP-first.

## Tests

```
zig build test          # or: zig test src/root.zig
```
