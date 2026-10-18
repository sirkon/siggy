# Schema guided parser.

The library should provide an API for "supported" structs which can be used as a schema for parsing.

The public API looks like

```
pub fn parser(T: type) type (
  return struct {
    // Here are field...

    // Initializes a parser with allocators. Use default printer if null.
    pub fn init(self: *Self, source_allocator: std.mem.Allocator, dst_allocator: std.mem.Allocator, printer: ?fn(allocator: std.mem.Allocator, diag: *Diagnostics) !void) !void

    pub fn parse(self: *Self, text: []const u8) error {ParsingError}!T
    pub fn parse_file(self: *Self, path: []const u8) error {ParsingError, FileIoError}!T
    pub fn stringify(self: *Self, value: T) []const u8
  }
}
```

And this thing must be THE ONLY public function listed in the ./src/root.zig. There can be public data types, but not functions besides this one.

and the source is a text that suits the grammar described in prompt.md

## Supported types (comptime, recursive)

`assertSupported(T)` (in `src/siggy/support.zig`) recursively checks at comptime;
unsupported types are `@compileError`:

?T T supported; absent assign or Block.empty -> null;
?T fields have an implicit default of null
struct S every field's type supported; if field doesn't have a default it must be
presented in the text. Only fields having defaults or ?T fields may not have
their values omitted.
[]T T supported
union(enum) U every variant's payload supported
std.AutoArrayHashMapUnmanaged(K, V) K and V supported; K is a leaf type or
[]const u8, bool, integer and unsigned integer; keys come from Literal
bool, uXXX, iXXX, usize, isize, fXXX leaf parsers from Literal
[]const u8 only from Quoted; Literal -> string is an error
enum E Literal -> variant name
T with pub decode/encode custom leaf; see below

Everything else: @compileError("unsupported type for siggy").

## Mapping rules (the contract; put in README)

AST node Target type Rule
---------------------------------------------------------------------------

Literal int/float/bool leaf parser; bad_number on failure
Literal enum E match variant name; unknown_variant
Literal []const u8 ERROR (strings must be Quoted)
Quoted []const u8 use decoded bytes, dup into value_arena
Quoted non-string ERROR
Block.document struct S field-by-field:
unknown key -> unknown_field
missing, no deflt,
not ?T -> missing_field
duplicate key -> duplicate_field
otherwise -> recurse
Block.document std.AutoArrayHashMapUnmanaged(K, V)
open dictionary: every assign is an entry;
unknown/missing/duplicate checks skipped;
keys deserialized from Literal as K
Block.list []T homogeneous: map each item via T;
respect max_list_len
Block.empty []T empty list
Block.empty struct S every field must have default or be ?T; missing_field if a field
has no default and is not ?T
Block.empty ?T null
Block.empty union(enum) U empty_not_allowed
Block.empty other empty_not_allowed
Tagged{tag,b} union(enum) U switch on tag; recurse into payload;
unknown_variant if no such tag
Tagged{tag,b} other unsupported_shape
Literal(s) union(enum) U if U has a variant with void payload named s
-> that variant
else if U has a variant named `literal`
(non-void) -> deserialize into it
else -> unknown_variant

Strictness:

- `Literal` never deserializes into a string. `name = my-service` is an error;
  write `name = "my-service"`.
- Unknown keys, duplicate keys: error. Missing keys: default or ?T, else error.
- Lists are homogeneous by T, not by AST shape: []MaskItem accepts a mix of
  Literal and Tagged (which is LITERAL block) because MaskItem is a union covering both.
- Max depth and max list length are enforced during recursion
  (max_depth_exceeded / max_list_len_exceeded).

## Custom types (decode/encode)

pub fn decode(
self: *Self,
source_arena: std.mem.Allocator, // ephemeral: parsing, scratch, diag.message
value_arena: std.mem.Allocator, // persistent: the decoded value itself
node: AstNode,
diag: *Diagnostic, // fill on error
) anyerror!void;

pub fn encode(
self: Self,
allocator: std.mem.Allocator,
) anyerror![]const u8;

Rules:

- `siggy` allocates `Self` in `value_arena` via `value_arena.create(T)` and
  calls `decode` on the `*Self`. `decode` does not allocate `Self` itself and
  does not return `Self` by value.
- `decode` puts everything that must outlive deserialization into `value_arena`;
  scratch goes into `source_arena`.
- `decode` fills `diag` on semantic errors. If it returns an error without
  filling `diag`, `siggy` fills the fallback (`.custom` + `@errorName`).
- `encode` returns arena-owned bytes; the caller does not free.

## Example (src/siggy/mask.zig)

pub const Range = struct { start: u32, end: u32 };

pub const MaskItem = union(enum) {
literal: u32, // from Literal("0"), Literal("1"), ...
range: Range, // from Tagged{"range", { start, end }}
};

pub const CpuConfig = struct {
index_threads_mask: []MaskItem,
pin_threads_mask: []MaskItem = &.{}, // default: empty
};

// parse via siggy.deserialize(CpuConfig, node, ...)

Example config (examples/cpu.cfg):

index_threads_mask = { 0 1 range { start = 10, end = 12 } }
pin_threads_mask = { 2, 3, 20, 21, }

Mapping of `0` -> MaskItem via the `literal` variant (non-void) -> u32 -> .literal(0).
Mapping of `range { ... }` -> Tagged -> switch on "range" -> Range -> .range(...).

## Tests

- lexer: LITERAL/QUOTED/COMMENT/COMMA/ASSIGN/START/END; `10..12` is one LITERAL;
  `0,1,2` -> LITERAL COMMA LITERAL COMMA LITERAL; `#` inside QUOTED is not a
  comment; BOM rejected; literal length limit; CRLF == LF.
- parser: happy paths (all value/list forms, tagged blocks, nesting, empty);
  disambiguation: `{ 0 1, 2 }` and `{ 0, 1 2 }` -> mixed_list_separators;
  `{ a = 1, b = 2 }` -> comma_in_document; `{ }` -> Block.empty.
- diagnostics: assert offset and code for a handful of failing inputs;
  exhaustive switch on ParseError in a test to prove the enum is covered.
- siggy: every supported type (primitives, enum, union, ?T, struct, []T,
  AutoArrayHashMapUnmanaged, custom); strictness (Literal->string error,
  unknown/duplicate/missing); `{ }` semantics per T; enum and union-with-void
  both work; max_depth / max_list_len enforced.
- ownership: after a successful parse+deserialize, free source_arena and verify
  the value is still usable (all strings are owned by value_arena; the only
  borrow is ast.Value.literal.text, documented and tested separately).
- higgy: golden strings for a few diagnostics.

## README sections

1. Thesis + non-goals (verbatim above).
2. Schema = structure; ADTs only for `tagged` / `list[tagged]`.
3. Grammar (verbatim) + disambiguation rules.
4. `Diagnostic` / `ParseError`; out-param + `anyerror`; `message` in source_arena.
5. Mapping table (verbatim) + strictness rules.
6. Supported types (comptime) + `@compileError` for the rest.
7. Custom types: `decode`/`encode` contract, who allocates `Self`.
8. Two-arena contract; `source_arena` may be freed after deserialize.
9. Example: `CpuConfig` and `examples/cpu.cfg`.
10. `higgy::render` only; no fmt/JSON in MVP.
11. What this is NOT: JSON superset, schema language, Zig-only, codegen-first,
    LSP-first.

## Style

Zig 0.17+ idioms. `[]const u8` for immutable slices. No global state.
