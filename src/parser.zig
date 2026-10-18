//! Recursive-descent parser for the siggy format.
//!
//! Allocation contract (two arenas, no individual frees):
//!   - `source_arena`: the token slice, decoded QUOTED payloads, and copies of
//!     every LITERAL used as a key, tag, or value. LITERAL tokens initially
//!     point into the caller's input buffer; the parser copies them so the
//!     returned AST never borrows memory owned by the caller.
//!   - `ast_arena`: `Document`, `Assign` arrays, `Block` nodes, `Value` arrays,
//!     and `Tagged` wrappers. Anything reachable from the returned `Document`
//!     lives here, except the string payloads noted above.
//!
//! Deinit is `ast_arena.deinit()` then `source_arena.deinit()` (order is not
//! significant since the arenas are independent).

const std = @import("std");
const ast = @import("siggy/ast.zig");
const lexer = @import("siggy/lexer.zig");
const diagnostic = @import("diagnostic.zig");
const options_mod = @import("options.zig");

pub const ParseError = diagnostic.ParsingError;
pub const Diagnostic = diagnostic.Diagnostic;
pub const Options = options_mod.Options;
pub const Value = ast.Value;
pub const Block = ast.Block;
pub const Assign = ast.Assign;
pub const Document = ast.Document;
pub const AstNode = ast.AstNode;
pub const Token = ast.Token;
pub const Kind = ast.Kind;

pub const Outcome = union(enum) {
    ok: Document,
    err: Diagnostic,
};

pub const LexOutcome = union(enum) {
    ok: []Token,
    err: Diagnostic,
};

pub fn parse(
    source: []const u8,
    source_arena: *std.heap.ArenaAllocator,
    ast_arena: *std.heap.ArenaAllocator,
) ParseError!Document {
    return parseWithOptions(source, source_arena, ast_arena, .{});
}

pub fn parseWithOptions(
    source: []const u8,
    source_arena: *std.heap.ArenaAllocator,
    ast_arena: *std.heap.ArenaAllocator,
    options: Options,
) ParseError!Document {
    return switch (parseDetailed(source, source_arena, ast_arena, options)) {
        .ok => |document| document,
        .err => |diag| diag.code,
    };
}

/// Lexes and parses, reporting the first failure with its source offset.
pub fn parseDetailed(
    source: []const u8,
    source_arena: *std.heap.ArenaAllocator,
    ast_arena: *std.heap.ArenaAllocator,
    options: Options,
) Outcome {
    return switch (lexer.lex(source, source_arena.allocator(), options)) {
        .err => |failure| .{ .err = failure.diagnostic },
        .ok => |tokens| parseTokensDetailed(tokens, source_arena, ast_arena),
    };
}

pub fn parseTokens(
    tokens: []const Token,
    source_arena: *std.heap.ArenaAllocator,
    ast_arena: *std.heap.ArenaAllocator,
) ParseError!Document {
    return switch (parseTokensDetailed(tokens, source_arena, ast_arena)) {
        .ok => |document| document,
        .err => |diag| diag.code,
    };
}

pub fn parseTokensDetailed(
    tokens: []const Token,
    source_arena: *std.heap.ArenaAllocator,
    ast_arena: *std.heap.ArenaAllocator,
) Outcome {
    var parser = Parser{
        .tokens = tokens,
        .source_allocator = source_arena.allocator(),
        .ast_allocator = ast_arena.allocator(),
    };
    const document = parser.parseTopLevel() catch {
        return .{ .err = parser.diagnostic orelse .{
            .offset = parser.peek().offset,
            .message = "parsing failed",
            .code = error.UnexpectedToken,
        } };
    };
    return .{ .ok = document };
}

pub fn lex(
    source: []const u8,
    source_arena: *std.heap.ArenaAllocator,
) ParseError![]Token {
    return lexOrError(source, source_arena, .{});
}

pub fn lexOrError(
    source: []const u8,
    source_arena: *std.heap.ArenaAllocator,
    options: Options,
) ParseError![]Token {
    return lexer.lexOrError(source, source_arena.allocator(), options);
}

pub fn lexWithOptions(
    source: []const u8,
    source_arena: *std.heap.ArenaAllocator,
    options: Options,
) LexOutcome {
    return switch (lexer.lex(source, source_arena.allocator(), options)) {
        .ok => |tokens| .{ .ok = tokens },
        .err => |failure| .{ .err = failure.diagnostic },
    };
}

const Parser = struct {
    tokens: []const Token,
    source_allocator: std.mem.Allocator,
    ast_allocator: std.mem.Allocator,
    index: usize = 0,
    diagnostic: ?Diagnostic = null,

    fn peek(self: *const Parser) Token {
        return self.tokens[self.index];
    }

    /// Token `offset` positions ahead, clamped to the final `eof` token.
    fn peekAt(self: *const Parser, offset: usize) Token {
        const target = @min(self.index + offset, self.tokens.len - 1);
        return self.tokens[target];
    }

    fn advance(self: *Parser) Token {
        const token = self.tokens[self.index];
        if (token.kind != .eof) self.index += 1;
        return token;
    }

    fn fail(self: *Parser, code: ParseError, offset: usize, message: []const u8) ParseError {
        self.diagnostic = .{ .code = code, .offset = offset, .message = message };
        return code;
    }

    fn failAtCurrent(self: *Parser, code: ParseError, message: []const u8) ParseError {
        return self.fail(code, self.peek().offset, message);
    }

    /// Copies a LITERAL's bytes into `source_arena`.
    fn ownLiteral(self: *Parser, text: []const u8) ParseError![]const u8 {
        return self.source_allocator.dupe(u8, text);
    }

    fn parseTopLevel(self: *Parser) ParseError!Document {
        const document = try self.parseAssigns(false);
        if (self.peek().kind != .eof) {
            return self.failAtCurrent(error.UnexpectedToken, "unexpected token after document");
        }
        return document;
    }

    /// `document = { assign } ;` — stops at END (when nested) or EOF.
    fn parseAssigns(self: *Parser, nested: bool) ParseError![]Assign {
        var list = std.ArrayList(Assign).empty;
        while (true) {
            const token = self.peek();
            switch (token.kind) {
                .eof => break,
                .end => break,
                // Disambiguation 4: COMMA is never allowed inside a document.
                .comma => return self.fail(
                    error.CommaInDocument,
                    token.offset,
                    if (nested) "comma is not allowed inside a document block" else "comma is not allowed between assignments",
                ),
                .literal => {},
                else => return self.failAtCurrent(error.UnexpectedToken, "expected an assignment key"),
            }

            const key = try self.ownLiteral(token.text);
            _ = self.advance();

            if (self.peek().kind != .assign) {
                return self.failAtCurrent(error.UnexpectedToken, "expected '=' after assignment key");
            }
            _ = self.advance();

            const value_offset = self.peek().offset;
            const value = try self.parseValue();
            try list.append(self.ast_allocator, .{
                .key = key,
                .value = value,
                .offset = token.offset,
                .value_offset = value_offset,
            });
        }
        return list.toOwnedSlice(self.ast_allocator);
    }

    /// `value = LITERAL block | block | LITERAL | QUOTED ;`
    fn parseValue(self: *Parser) ParseError!Value {
        const token = self.peek();
        switch (token.kind) {
            .literal => {
                const text = try self.ownLiteral(token.text);
                _ = self.advance();

                // Disambiguation 2: LITERAL followed by START is Tagged.
                if (self.peek().kind == .start) {
                    const block = try self.parseBlock();
                    return .{ .tagged = .{ .tag = text, .block = block, .offset = token.offset } };
                }
                return .{ .literal = text };
            },
            .start => {
                const block = try self.parseBlock();
                return .{ .block = block };
            },
            .quoted => {
                _ = self.advance();
                return .{ .quoted = token.text };
            },
            else => return self.failAtCurrent(error.UnexpectedToken, "expected a value"),
        }
    }

    /// `block = START END | START document END | START list END ;`
    fn parseBlock(self: *Parser) ParseError!*Block {
        const block = try self.ast_allocator.create(Block);
        const start = self.advance();
        std.debug.assert(start.kind == .start);

        // Disambiguation 1a: START END is an empty block.
        if (self.peek().kind == .end) {
            _ = self.advance();
            block.* = .empty;
            return block;
        }

        // Disambiguation 1b: peek two tokens; LITERAL + ASSIGN means a document.
        if (self.peek().kind == .literal and self.peekAt(1).kind == .assign) {
            const document = try self.parseAssigns(true);
            if (self.peek().kind != .end) {
                return self.failAtCurrent(error.UnexpectedToken, "expected '}' to close block");
            }
            _ = self.advance();
            block.* = .{ .document = document };
            return block;
        }

        const items = try self.parseList();
        block.* = .{ .list = items };
        return block;
    }

    /// `list = list_space | list_comma ;`
    fn parseList(self: *Parser) ParseError![]Value {
        if (self.peek().kind == .comma) {
            return self.failAtCurrent(error.EmptyList, "list cannot start with a comma");
        }

        var items = std.ArrayList(Value).empty;
        try items.append(self.ast_allocator, try self.parseValue());

        // Disambiguation 3: the separator seen after the first item fixes the
        // mode for the whole list.
        if (self.peek().kind == .comma) {
            _ = self.advance();
            while (self.peek().kind != .end) {
                if (self.peek().kind == .eof) {
                    return self.failAtCurrent(error.UnexpectedToken, "expected '}' to close list");
                }
                try items.append(self.ast_allocator, try self.parseValue());
                if (self.peek().kind != .comma) break;
                _ = self.advance();
            }
            if (self.peek().kind != .end) {
                return self.failAtCurrent(error.MixedListSeparators, "expected ',' or '}' in comma-separated list");
            }
            _ = self.advance();
            return items.toOwnedSlice(self.ast_allocator);
        }

        while (self.peek().kind != .end) {
            switch (self.peek().kind) {
                .eof => return self.failAtCurrent(error.UnexpectedToken, "expected '}' to close list"),
                .comma => return self.failAtCurrent(
                    error.MixedListSeparators,
                    "comma used in a space-separated list",
                ),
                else => try items.append(self.ast_allocator, try self.parseValue()),
            }
        }
        _ = self.advance();
        return items.toOwnedSlice(self.ast_allocator);
    }
};

// ------------------------------------------------------------------ tests

const testing = std.testing;

const Harness = struct {
    source_arena: std.heap.ArenaAllocator,
    ast_arena: std.heap.ArenaAllocator,

    fn init(child: std.mem.Allocator) Harness {
        return .{
            .source_arena = std.heap.ArenaAllocator.init(child),
            .ast_arena = std.heap.ArenaAllocator.init(child),
        };
    }

    fn deinit(self: *Harness) void {
        self.ast_arena.deinit();
        self.source_arena.deinit();
    }

    fn parseDocument(self: *Harness, input: []const u8) !Document {
        return parse(input, &self.source_arena, &self.ast_arena);
    }

    fn parseOutcome(self: *Harness, input: []const u8, options: Options) Outcome {
        return parseDetailed(input, &self.source_arena, &self.ast_arena, options);
    }
};

fn expectError(input: []const u8, expected: ParseError) !void {
    var harness = Harness.init(testing.allocator);
    defer harness.deinit();
    try testing.expectError(expected, harness.parseDocument(input));
}

fn expectLiteral(expected: []const u8, value: Value) !void {
    try testing.expect(value == .literal);
    try testing.expectEqualStrings(expected, value.literal);
}

test "top-level: empty input" {
    var harness = Harness.init(testing.allocator);
    defer harness.deinit();

    const document = try harness.parseDocument("");
    try testing.expectEqual(@as(usize, 0), document.len);

    const only_comment = try harness.parseDocument("# nothing here\n\n#and here");
    try testing.expectEqual(@as(usize, 0), only_comment.len);
}

test "top-level: trailing END is rejected" {
    try expectError("}", error.UnexpectedToken);
}

test "top-level: one assign" {
    var harness = Harness.init(testing.allocator);
    defer harness.deinit();

    const document = try harness.parseDocument("key = value");
    try testing.expectEqual(@as(usize, 1), document.len);
    try testing.expectEqualStrings("key", document[0].key);
    try expectLiteral("value", document[0].value);
}

test "top-level: many assigns" {
    var harness = Harness.init(testing.allocator);
    defer harness.deinit();

    const document = try harness.parseDocument("a = 1 b = 2\nc = 3");
    try testing.expectEqual(@as(usize, 3), document.len);
    try testing.expectEqualStrings("a", document[0].key);
    try testing.expectEqualStrings("b", document[1].key);
    try testing.expectEqualStrings("c", document[2].key);
    try expectLiteral("3", document[2].value);
}

test "value: bare literal" {
    var harness = Harness.init(testing.allocator);
    defer harness.deinit();

    const document = try harness.parseDocument("v = hello.world");
    try expectLiteral("hello.world", document[0].value);
}

test "value: quoted with escapes" {
    var harness = Harness.init(testing.allocator);
    defer harness.deinit();

    const document = try harness.parseDocument(
        \\v = "he said \"hi\" and a back\\slash"
    );
    const value = document[0].value;
    try testing.expect(value == .quoted);
    try testing.expectEqualStrings("he said \"hi\" and a back\\slash", value.quoted);
}

test "value: quoted empty string" {
    var harness = Harness.init(testing.allocator);
    defer harness.deinit();

    const document = try harness.parseDocument("v = \"\"");
    try testing.expect(document[0].value == .quoted);
    try testing.expectEqualStrings("", document[0].value.quoted);
}

test "value: block document" {
    var harness = Harness.init(testing.allocator);
    defer harness.deinit();

    const document = try harness.parseDocument("a = { b = 1 c = 2 }");
    const value = document[0].value;
    try testing.expect(value == .block);
    try testing.expect(value.block.* == .document);
    try testing.expectEqual(@as(usize, 2), value.block.document.len);
    try testing.expectEqualStrings("b", value.block.document[0].key);
    try expectLiteral("2", value.block.document[1].value);
}

test "value: block list" {
    var harness = Harness.init(testing.allocator);
    defer harness.deinit();

    const document = try harness.parseDocument("a = { 1 2 3 }");
    const value = document[0].value;
    try testing.expect(value == .block);
    try testing.expect(value.block.* == .list);
    try testing.expectEqual(@as(usize, 3), value.block.list.len);
    try expectLiteral("1", value.block.list[0]);
    try expectLiteral("3", value.block.list[2]);
}

test "value: tagged block" {
    var harness = Harness.init(testing.allocator);
    defer harness.deinit();

    const document = try harness.parseDocument("a = point { x = 1 y = 2 }");
    const value = document[0].value;
    try testing.expect(value == .tagged);
    try testing.expectEqualStrings("point", value.tagged.tag);
    try testing.expect(value.tagged.block.* == .document);
    try testing.expectEqual(@as(usize, 2), value.tagged.block.document.len);
}

test "value: tagged empty block" {
    var harness = Harness.init(testing.allocator);
    defer harness.deinit();

    const document = try harness.parseDocument("a = tagged { }");
    const value = document[0].value;
    try testing.expect(value == .tagged);
    try testing.expectEqualStrings("tagged", value.tagged.tag);
    try testing.expect(value.tagged.block.* == .empty);
}

test "value: tagged list" {
    var harness = Harness.init(testing.allocator);
    defer harness.deinit();

    const document = try harness.parseDocument("a = list { 1, 2, }");
    const value = document[0].value;
    try testing.expect(value == .tagged);
    try testing.expect(value.tagged.block.* == .list);
    try testing.expectEqual(@as(usize, 2), value.tagged.block.list.len);
}

test "value: nested list of tagged documents" {
    var harness = Harness.init(testing.allocator);
    defer harness.deinit();

    const document = try harness.parseDocument("items = { a { b = 1 } c { d = 2 } }");
    const list = document[0].value.block.list;
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqualStrings("a", list[0].tagged.tag);
    try testing.expectEqualStrings("b", list[0].tagged.block.document[0].key);
    try testing.expectEqualStrings("c", list[1].tagged.tag);
    try testing.expectEqualStrings("d", list[1].tagged.block.document[0].key);
}

test "value: block document as list item" {
    var harness = Harness.init(testing.allocator);
    defer harness.deinit();

    const document = try harness.parseDocument("a = { { b = 1 } { c = 2 } }");
    const list = document[0].value.block.list;
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expect(list[0] == .block);
    try testing.expect(list[0].block.* == .document);
    try testing.expectEqualStrings("c", list[1].block.document[0].key);
}

test "list: space-only" {
    var harness = Harness.init(testing.allocator);
    defer harness.deinit();

    const document = try harness.parseDocument("a = { 0 1 2 }");
    try testing.expectEqual(@as(usize, 3), document[0].value.block.list.len);
}

test "list: comma-only" {
    var harness = Harness.init(testing.allocator);
    defer harness.deinit();

    const document = try harness.parseDocument("a = { 0,1,2 }");
    const list = document[0].value.block.list;
    try testing.expectEqual(@as(usize, 3), list.len);
    try expectLiteral("0", list[0]);
    try expectLiteral("2", list[2]);
}

test "list: trailing comma" {
    var harness = Harness.init(testing.allocator);
    defer harness.deinit();

    const document = try harness.parseDocument("a = { 0, 1, 2, }");
    try testing.expectEqual(@as(usize, 3), document[0].value.block.list.len);
}

test "list: single item" {
    var harness = Harness.init(testing.allocator);
    defer harness.deinit();

    const document = try harness.parseDocument("a = { 42 }");
    try testing.expectEqual(@as(usize, 1), document[0].value.block.list.len);

    const with_comma = try harness.parseDocument("a = { 42, }");
    try testing.expectEqual(@as(usize, 1), with_comma[0].value.block.list.len);
}

test "list: empty block is preserved without interpretation" {
    var harness = Harness.init(testing.allocator);
    defer harness.deinit();

    const document = try harness.parseDocument("a = { }");
    try testing.expect(document[0].value.block.* == .empty);
}

test "list: mixed separators rejected, space first" {
    try expectError("a = { 0 1, 2 }", error.MixedListSeparators);
}

test "list: mixed separators rejected, comma first" {
    try expectError("a = { 0, 1 2 }", error.MixedListSeparators);
}

test "list: leading or doubled comma rejected" {
    try expectError("a = { , }", error.EmptyList);
    try expectError("a = { , 1 }", error.EmptyList);
    try expectError("a = { 0,, 1 }", error.UnexpectedToken);
}

test "comments: full-line and trailing" {
    var harness = Harness.init(testing.allocator);
    defer harness.deinit();

    const document = try harness.parseDocument(
        \\# leading comment
        \\a = 1 # trailing comment
        \\# between
        \\b = 2
    );
    try testing.expectEqual(@as(usize, 2), document.len);
    try expectLiteral("1", document[0].value);
    try expectLiteral("2", document[1].value);
}

test "comments: hash inside quoted is not a comment" {
    var harness = Harness.init(testing.allocator);
    defer harness.deinit();

    const document = try harness.parseDocument("a = \"x # y\" b = 2");
    try testing.expectEqual(@as(usize, 2), document.len);
    try testing.expect(document[0].value == .quoted);
    try testing.expectEqualStrings("x # y", document[0].value.quoted);
}

test "errors: missing assign" {
    try expectError("a 1", error.UnexpectedToken);
    try expectError("a = ", error.UnexpectedToken);
    try expectError("a", error.UnexpectedToken);
}

test "errors: missing end" {
    try expectError("a = { b = 1", error.UnexpectedToken);
    try expectError("a = { 1 2", error.UnexpectedToken);
}

test "errors: comma in document" {
    try expectError("a = { b = 1, c = 2 }", error.CommaInDocument);
    try expectError("a = 1, b = 2", error.CommaInDocument);
}

test "errors: offsets are reported" {
    var harness = Harness.init(testing.allocator);
    defer harness.deinit();

    const outcome = harness.parseOutcome("a = 1, b = 2", .{});
    try testing.expect(outcome == .err);
    try testing.expectEqual(@as(usize, 5), outcome.err.offset);
    try testing.expectEqual(ParseError.CommaInDocument, outcome.err.code);

    const missing_end = harness.parseOutcome("a = { b = 1", .{});
    try testing.expect(missing_end == .err);
    try testing.expectEqual(@as(usize, 11), missing_end.err.offset);
    try testing.expectEqual(ParseError.UnexpectedToken, missing_end.err.code);
}

test "arenas: ast survives freeing the input buffer" {
    var source_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer source_arena.deinit();
    var ast_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer ast_arena.deinit();

    const input = try testing.allocator.dupe(u8, "key = tag { \"quoted \\\"value\\\"\" 10..12 }");
    const document = try parse(input, &source_arena, &ast_arena);
    testing.allocator.free(input);

    try testing.expectEqual(@as(usize, 1), document.len);
    try testing.expectEqualStrings("key", document[0].key);
    try testing.expect(document[0].value == .tagged);
    try testing.expectEqualStrings("tag", document[0].value.tagged.tag);

    const list = document[0].value.tagged.block.list;
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expect(list[0] == .quoted);
    try testing.expectEqualStrings("quoted \"value\"", list[0].quoted);
    try expectLiteral("10..12", list[1]);
}

test "arenas: both arenas are used" {
    var source_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer source_arena.deinit();
    var ast_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer ast_arena.deinit();

    _ = try lex("\"abc\\\"\"", &source_arena);
    try testing.expect(source_arena.queryCapacity() > 0);

    const document = try parse("a = 1 b = { c = 2 }", &source_arena, &ast_arena);
    try testing.expect(ast_arena.queryCapacity() > 0);
    try testing.expectEqual(@as(usize, 2), document.len);
}

test "arenas: resetting ast arena keeps source arena usable" {
    var harness = Harness.init(testing.allocator);
    defer harness.deinit();

    _ = try harness.parseDocument("a = 1");
    _ = harness.ast_arena.reset(.retain_capacity);
    const document = try harness.parseDocument("b = 2");
    try testing.expectEqualStrings("b", document[0].key);
}

test "ParseError enum is exhaustively classified" {
    inline for (@typeInfo(ParseError).error_set.error_names.?) |name| {
        const err = @field(ParseError, name);
        switch (err) {
            error.UnexpectedToken,
            error.UnterminatedQuote,
            error.InvalidEscape,
            error.NewlineInQuote,
            error.BomPresent,
            error.LiteralTooLong,
            error.EmptyList,
            error.MixedListSeparators,
            error.CommaInDocument,
            error.BadNumber,
            error.UnknownVariant,
            error.UnknownField,
            error.MissingField,
            error.DuplicateField,
            error.EmptyNotAllowed,
            error.UnsupportedShape,
            error.ExpectedQuoted,
            error.MaxDepthExceeded,
            error.MaxListLenExceeded,
            error.Custom,
            error.OutOfMemory,
            => {},
        }
    }
}
