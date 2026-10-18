Implement a recursive-descent parser in Zig for the grammar below.

## Grammar (authoritative)

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

## Disambiguation

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

## Lexer requirements

- Input: []const u8. Output: a slice of Token.
- Token kinds: assign, start, end, comma, literal, quoted, eof.
- LITERAL: maximal run of bytes with value > 32 that are not one of `= { } , " #`.
  An empty LITERAL is never emitted.
- QUOTED: starts with `"`, ends at the next unescaped `"`. Support exactly `\"` and `\\`
  inside; any other backslash sequence is an error. A newline inside QUOTED is an error.
  Store the *decoded* bytes (escapes resolved) in the token payload.
- COMMENT: `#` until (not including) `\n`; skipped, never emitted.
- Whitespace: space, `\t`, `\r`, `\n` separate tokens and are otherwise ignored.
  `\r\n` is treated as `\n`.
- A leading UTF-8 BOM is an error (do not silently skip it).
- Emit a final `eof` token. The parser relies on it; no bounds-checking of the token
  slice beyond `eof` is needed.
- Reject a LITERAL longer than a configurable `max_literal_len` (default 4096) with a
  clear error, to avoid unbounded memory use.

## AST

Define a tagged union AST. Suggested shape (adjust names to Zig idioms):

  pub const Value = union(enum) {
      literal: []const u8,            // decoded? no — raw bytes, see note below
      quoted:  []const u8,            // decoded (escapes resolved)
      block:   *Block,
      tagged:  struct { tag: []const u8, block: *Block },  // LITERAL block
  };

  pub const Block = union(enum) {
      document: []Assign,
      list:     []Value,             // mode (space/comma) is a parse-time concern;
                                     // it does not need to be preserved in the AST
                                     // unless you want it for diagnostics.
  };

  pub const Assign = struct { key: []const u8, value: Value };

  pub const Document = []Assign;

Notes:
- `literal` payload is the raw slice of the source (no unescaping — LITERAL has no escapes).
- `quoted` payload is the decoded slice (escapes resolved); decoding must allocate.
- Slices in the AST point into the two arenas described below, never into locals.

## Allocators (hard requirement)

Use exactly two arena allocators, with clearly separated lifetimes:

1. `source_arena` — owns everything derived from the source text that must outlive
   parsing but does not need individual frees: the token slice itself, decoded QUOTED
   payloads, and any source-derived strings kept in the AST (LITERAL slices may point
   directly into the input buffer if the input is owned by the caller; document this).
2. `ast_arena` — owns the AST nodes: `Document`, `Assign` arrays, `Block`, `Value`
   arrays, `tagged` wrappers. Every `[]T` in the AST is allocated from this arena.

Rules:
- No individual `free` calls. Deinit is `arena.deinit()` for each arena, in reverse
  order of creation (ast_arena first, then source_arena) if it matters for debugging;
  in practice both are independent.
- No allocations outside the two arenas (no `page_allocator` sprinkled around).
- The parser takes both arenas by pointer; it does not own them.
- Document in code comments which arena each allocation goes to. If you find a case
  where the split is ambiguous, prefer `ast_arena` for anything reachable from the
  returned `Document`, and `source_arena` for token/lexeme storage.

## Public API (suggested)

  pub const ParseError = error{ ... };   // enumerate: UnexpectedToken, UnterminatedQuote,
                                         // InvalidEscape, EmptyList, MixedListSeparators,
                                         // CommaInDocument, LiteralTooLong, BomPresent,
                                         // NewlineInQuote, ...
  pub const Diagnostic = struct { offset: usize, message: []const u8 };

  pub fn parse(
      source: []const u8,
      source_arena: *std.heap.ArenaAllocator,
      ast_arena: *std.heap.ArenaAllocator,
  ) ParseError!Document;

  // Optional: a lexer entry point, useful for tests.
  pub fn lex(source: []const u8, arena: *std.heap.ArenaAllocator) ParseError![]Token;

Errors must carry an offset. Prefer returning a struct
`{ doc: Document, diagnostics: []Diagnostic }` if you want to collect multiple errors;
otherwise fail fast on the first error but still report its offset.

## Code layout

The code must be in one file called `parser.zig`. The next step (future prompts) will address
mapping resulted AST into a struct and back.

## Testing

Provide unit tests (std.testing) covering at least:
- top-level: empty input, one assign, many assigns.
- value: bare LITERAL, QUOTED (with \" and \\), block-document, block-list,
  LITERAL block (tagged).
- lists: space-only, comma-only, trailing comma, single item, empty `{ }` rejected,
  mixed separators rejected (both directions: `0 1, 2` and `0, 1 2`).
- comments: full-line, trailing after a value, `#` inside QUOTED must NOT start a comment.
- lexer edge cases: `10..12` is one LITERAL; `0,1,2` without spaces lexes as
  LITERAL COMMA LITERAL COMMA LITERAL; BOM rejected; literal length limit.
- errors: missing ASSIGN, missing END, unterminated quote, newline in quote,
  COMMA inside document block, empty list.
- arena behavior: after `parse`, both arenas own what they should; a test that walks
  the AST after the input buffer is freed (if you copy LITERAL slices) or documents
  that LITERAL slices borrow the input.

## Deliverables

- `lexer.zig` — tokens + lexer.
- `parser.zig` — recursive descent, AST, public `parse`.
- `ast.zig` — AST types (if you prefer to split).
- `main_test.zig` or `tests.zig` — the tests above.
- A short `README.md` section: the grammar (verbatim from this prompt), the
  disambiguation rules, the two-arena contract, and the public API.

## Style

- Zig 0.17+ idioms: `std.mem`, `std.ascii`, explicit error sets, no `anytype` in public
  API unless justified.
- Prefer `[]const u8` over `[]u8` where mutation is not needed.
- No global state; everything through parameters.
- Comments only where the grammar's disambiguation rules are implemented (peek(1),
  peek(2), list-mode fixation) — those are the spots a reviewer will look at first.
  