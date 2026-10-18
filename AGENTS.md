# AGENTS.md

siggy is a Zig library that turns a Zig type into a config-file parser. There
is no schema language: `siggy.parser(T)` builds a type-specialized
lexer/parser/deserializer at comptime for the config grammar in `GRAMMAR.md`.

## Commands

```sh
zig build test          # full suite (78 tests) via the "test" step
zig test src/root.zig   # same tests without the build system
zig test src/root.zig --test-filter higgy   # narrow a run
zig fmt --check src build.zig               # formatting gate (currently clean)
```

- Toolchain is Zig **0.17.0** (`build.zig.zon` `minimum_zig_version`). The code
  relies on recent 0.17 idioms; older compilers will not build it.
- `zig build` with no step is a no-op: the only artifact is the test module.
  There is no executable, library artifact, lint step, or CI config.
- Do **not** run `zig test` against a file under `src/siggy/`: those files
  import `../diagnostic.zig`, which fails with "import of file outside module
  path". Always test through `src/root.zig`.
- Tests read `examples/cpu.cfg` and use paths like `.zig-cache/tmp/...`, so run
  commands from the repository root.

## Layout and data flow

```
src/root.zig          public surface; only public function is `parser`
src/parser.zig        recursive-descent parser (AST) + public parse entry points
src/siggy/lexer.zig   tokenizer
src/siggy/ast.zig     Value / Block / Assign / Document node types
src/siggy/schema.zig  parser(T): Decoder (AST -> T) and Encoder (T -> text)
src/siggy/support.zig comptime assertSupported / leafKind / isMapType / isCustom
src/siggy/higgy.zig   the only diagnostic renderer (line/column/caret block)
src/siggy/mask.zig    worked example (CpuConfig) used by tests
src/diagnostic.zig    ParsingError set, Diagnostic, Diagnostics, Printer
src/options.zig       Options limits (max_literal_len, max_depth, max_list_len, max_file_size)
src/test.zig          round-trip tests for a deployment-shaped Config
src/tests.zig         end-to-end schema tests
```

Flow: `root.parser(T)` -> `schema.parser(T)` -> `parser.parseDetailed`
(lexer + parser) -> `Decoder.decode` -> `T`. Encoding is the mirror `Encoder`
in `schema.zig`, exposed as `stringify`.

## Invariants that tests enforce

- `root.zig` may expose **exactly one public function**, `parser`
  (`src/tests.zig:481` "root: parser is the only public function"). Data types
  and the `higgy` namespace are fine; adding another public function there
  breaks that test. `higgy` exposes only `Location`, not `render`.
- Tests are co-located in every source file, but a new test file must be added
  to the test block in `src/root.zig:31-41` or it silently never runs.
  `src/test.zig` and `src/tests.zig` are imported explicitly; the rest use
  `refAllDecls`.
- Error codes live in one flat set, `ParsingError` (`src/diagnostic.zig:6`),
  covering lexing, parsing, and mapping. `src/parser.zig:667` asserts the enum
  is exhaustively classified; add a case there when adding an error.

## Non-obvious behaviors

- **Strings require quotes.** A `LITERAL` never decodes into `[]const u8`
  (`ExpectedQuoted`). `name = my-service` is an error; `name = "my-service"` is
  correct. This trips up anyone writing fixtures.
- **`{ }` is uninterpreted by the parser.** Its meaning (empty list, empty
  struct, `null`, or `EmptyNotAllowed`) is decided in the schema layer.
- **Lists are homogeneous by `T`, not AST shape.** `[]MaskItem` accepts a mix of
  `0` and `range { ... }` because the union covers both.
- **Union conventions.** A tagged block `tag { ... }` picks a union variant by
  name; a bare literal picks a `void` variant with that name first, otherwise a
  non-void variant named exactly `literal` (`src/siggy/schema.zig:491`). A
  non-void leaf payload written as `tag { value }` is unwrapped by
  `taggedPayloadNode` (`schema.zig:585`); this is the only tagged-leaf form the
  grammar allows.
- **Two different allocator contracts.** The low-level parser takes two
  `*std.heap.ArenaAllocator` (`source_arena`, `ast_arena`); the schema layer
  takes two plain allocators (`source_allocator` ephemeral, `value_allocator`
  persistent). `parser(T).parse` frees its scratch arenas before returning, so
  the decoded value must own every string/slice. Keep it that way; the test
  "value survives resetting the source allocator" guards it.
- **`init` resets `options`.** `p.init(...)` sets `self.options = .{}`, so
  customize limits *after* init (`src/tests.zig:306-310`).
- **Diagnostics.** Messages are allocated in scratch memory while a printer
  runs; `parse` copies code/offset/message into the value allocator afterwards
  (`schema.zig:140`). Custom printers must not retain `*Diagnostics`.
- **Default printer writes to stderr.** Tests use a `silentPrinter` to avoid
  noise; follow that pattern for error-expecting tests.
- **`stringify`** returns a slice owned by the value allocator (`""` on failure
  with `diagnostic` set). `null` optional fields are omitted rather than written
  as `{ }`; the non-void `literal` union variant is written bare so it
  round-trips.
- **Custom types** are any struct with `decode`/`encode` matching the
  signatures in `src/siggy/support.zig:119`. siggy allocates `Self` with
  `value_allocator.create(T)`; `decode` must not allocate `Self`. Examples:
  `src/tests.zig:15` (`Duration`) and `src/test.zig:46` (`CoresMask`).
- **Maps** are recognized structurally (`isMapType`, `support.zig:90`), not by
  exact type name, so any `AutoArrayHashMapUnmanaged` spelling works. Map keys
  come from literals and must be `bool`/int/enum/`[]const u8`.

## Documentation sources of truth

- `GRAMMAR.md` and `schema.md` are the specs (grammar, disambiguation,
  mapping table, allocator rules). `README.md` duplicates the grammar and
  mapping tables; update it in lockstep with spec changes.
- `prompt.md` is a historical task brief from when the code was a single
  `parser.zig`. Its file-layout "deliverables" are stale; do not restructure
  the repo to match it.

## Style

- Module-level `//!` docs on every file, `//` comments only for the grammar
  disambiguation points and allocator contracts.
- `[]const u8` for immutable slices; no global state; explicit error sets in
  public APIs.
- Grammar rules are implemented with `peek`/`peekAt` token lookahead; list
  separator mode is fixed after the first item (`src/parser.zig:280`).
- Locals/fields use `snake_case`, types `PascalCase`, matching existing files.
