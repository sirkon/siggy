//! Tokenizer for the siggy format.
//!
//! Produces `eof`-terminated token slices. Token storage and decoded QUOTED
//! payloads are allocated from the allocator the caller passes in (the
//! `source_arena` of the two-arena contract). Diagnostic messages are also
//! allocated there so they stay valid while the caller renders them.

const std = @import("std");
const ast = @import("ast.zig");
const diagnostic = @import("../diagnostic.zig");
const options_mod = @import("../options.zig");

pub const Kind = ast.Kind;
pub const Token = ast.Token;
pub const ParseError = diagnostic.ParsingError;
pub const Diagnostic = diagnostic.Diagnostic;
pub const Options = options_mod.Options;

pub const Failure = struct {
    diagnostic: Diagnostic,
};

pub const Result = union(enum) {
    ok: []Token,
    err: Failure,
};

pub fn lex(source: []const u8, allocator: std.mem.Allocator, options: Options) Result {
    var lexer = Lexer{
        .source = source,
        .allocator = allocator,
        .options = options,
        .tokens = std.ArrayList(Token).empty,
    };
    const tokens = lexer.run() catch |err| return .{ .err = .{ .diagnostic = lexer.diagnostic orelse .{
        .code = error.OutOfMemory,
        .offset = lexer.index,
        .message = @errorName(err),
    } } };
    return .{ .ok = tokens };
}

pub fn lexOrError(source: []const u8, allocator: std.mem.Allocator, options: Options) ParseError![]Token {
    return switch (lex(source, allocator, options)) {
        .ok => |tokens| tokens,
        .err => |failure| failure.diagnostic.code,
    };
}

const Lexer = struct {
    source: []const u8,
    allocator: std.mem.Allocator,
    options: Options,
    index: usize = 0,
    tokens: std.ArrayList(Token),
    diagnostic: ?Diagnostic = null,

    fn run(self: *Lexer) ParseError![]Token {
        // A leading UTF-8 BOM is rejected rather than silently skipped.
        if (std.mem.startsWith(u8, self.source, "\xEF\xBB\xBF")) {
            return self.fail(error.BomPresent, 0, "UTF-8 BOM is not allowed");
        }

        while (self.index < self.source.len) {
            const c = self.source[self.index];
            switch (c) {
                ' ', '\t', '\r', '\n' => self.index += 1,
                '#' => self.skipComment(),
                '=' => try self.pushSingle(.assign),
                '{' => try self.pushSingle(.start),
                '}' => try self.pushSingle(.end),
                ',' => try self.pushSingle(.comma),
                '"' => try self.lexQuoted(),
                else => {
                    // Bytes <= 32 that are not whitespace are not literals.
                    if (c <= 32) {
                        return self.fail(error.UnexpectedToken, self.index, "unexpected control character");
                    }
                    try self.lexLiteral();
                },
            }
        }

        try self.tokens.append(self.allocator, .{
            .kind = .eof,
            .text = "",
            .offset = self.source.len,
        });
        return self.tokens.toOwnedSlice(self.allocator);
    }

    fn pushSingle(self: *Lexer, kind: Kind) !void {
        try self.tokens.append(self.allocator, .{
            .kind = kind,
            .text = self.source[self.index .. self.index + 1],
            .offset = self.index,
        });
        self.index += 1;
    }

    fn skipComment(self: *Lexer) void {
        while (self.index < self.source.len and self.source[self.index] != '\n') {
            self.index += 1;
        }
    }

    fn lexLiteral(self: *Lexer) !void {
        const start = self.index;
        while (self.index < self.source.len) {
            const c = self.source[self.index];
            if (c <= 32 or c == '=' or c == '{' or c == '}' or
                c == ',' or c == '"' or c == '#')
            {
                break;
            }
            self.index += 1;
        }

        const text = self.source[start..self.index];
        if (text.len > self.options.max_literal_len) {
            return self.fail(
                error.LiteralTooLong,
                start,
                try std.fmt.allocPrint(
                    self.allocator,
                    "literal is {d} bytes, limit is {d}",
                    .{ text.len, self.options.max_literal_len },
                ),
            );
        }
        try self.tokens.append(self.allocator, .{ .kind = .literal, .text = text, .offset = start });
    }

    fn lexQuoted(self: *Lexer) !void {
        const start = self.index;
        self.index += 1;
        const content_start = self.index;

        // Pass one: validate escapes and determine the decoded length.
        var decoded_len: usize = 0;
        while (self.index < self.source.len) {
            const c = self.source[self.index];
            if (c == '"') break;
            if (c == '\n' or c == '\r') {
                return self.fail(error.NewlineInQuote, self.index, "newline inside quoted literal");
            }
            if (c == '\\') {
                if (self.index + 1 >= self.source.len) {
                    return self.fail(error.UnterminatedQuote, start, "unterminated quoted literal");
                }
                const escaped = self.source[self.index + 1];
                if (escaped == '\n' or escaped == '\r') {
                    return self.fail(error.NewlineInQuote, self.index + 1, "newline inside quoted literal");
                }
                if (escaped != '"' and escaped != '\\') {
                    return self.fail(error.InvalidEscape, self.index, "invalid escape sequence; only \\\" and \\\\ are allowed");
                }
                decoded_len += 1;
                self.index += 2;
            } else {
                decoded_len += 1;
                self.index += 1;
            }
        }

        if (self.index >= self.source.len) {
            return self.fail(error.UnterminatedQuote, start, "unterminated quoted literal");
        }

        const closing = self.index;
        self.index += 1;

        // Decoding always allocates from the source arena.
        const decoded = try self.allocator.alloc(u8, decoded_len);
        var src = content_start;
        var dst: usize = 0;
        while (src < closing) {
            if (self.source[src] == '\\') src += 1;
            decoded[dst] = self.source[src];
            dst += 1;
            src += 1;
        }

        try self.tokens.append(self.allocator, .{
            .kind = .quoted,
            .text = decoded,
            .offset = start,
        });
    }

    fn fail(self: *Lexer, code: ParseError, offset: usize, message: []const u8) ParseError {
        self.diagnostic = .{ .code = code, .offset = offset, .message = message };
        return code;
    }
};

const testing = std.testing;

fn expectKinds(expected: []const Kind, tokens: []const Token) !void {
    try testing.expectEqual(expected.len, tokens.len);
    for (expected, tokens) |kind, token| try testing.expectEqual(kind, token.kind);
}

test "lexer: 10..12 is one literal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tokens = try lexOrError("10..12", arena.allocator(), .{});
    try expectKinds(&.{ .literal, .eof }, tokens);
    try testing.expectEqualStrings("10..12", tokens[0].text);
}

test "lexer: 0,1,2 without spaces" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tokens = try lexOrError("0,1,2", arena.allocator(), .{});
    try expectKinds(&.{ .literal, .comma, .literal, .comma, .literal, .eof }, tokens);
}

test "lexer: sample token stream" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tokens = try lexOrError("a = { b } \"q\" # skip\n=", arena.allocator(), .{});
    try expectKinds(&.{
        .literal, .assign, .start, .literal, .end, .quoted, .assign, .eof,
    }, tokens);
    try testing.expectEqual(@as(usize, 0), tokens[0].offset);
}

test "lexer: utf8 bom rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const result = lex("\xEF\xBB\xBFa = 1", arena.allocator(), .{});
    try testing.expect(result == .err);
    try testing.expectEqual(ParseError.BomPresent, result.err.diagnostic.code);
    try testing.expectEqual(@as(usize, 0), result.err.diagnostic.offset);
}

test "lexer: literal length limit" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    _ = try lexOrError("1234", arena.allocator(), .{ .max_literal_len = 4 });

    const result = lex("12345", arena.allocator(), .{ .max_literal_len = 4 });
    try testing.expect(result == .err);
    try testing.expectEqual(ParseError.LiteralTooLong, result.err.diagnostic.code);
    try testing.expectEqual(@as(usize, 0), result.err.diagnostic.offset);
}

test "lexer: default literal limit is 4096" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const input = try testing.allocator.alloc(u8, 4097);
    defer testing.allocator.free(input);
    @memset(input, 'x');

    _ = try lexOrError(input[0..4096], arena.allocator(), .{});
    try testing.expectError(error.LiteralTooLong, lexOrError(input, arena.allocator(), .{}));
}

test "lexer: crlf and control characters" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tokens = try lexOrError("a\r\nb", arena.allocator(), .{});
    try expectKinds(&.{ .literal, .literal, .eof }, tokens);

    try testing.expectError(error.UnexpectedToken, lexOrError("a = \x01", arena.allocator(), .{}));
}

test "lexer: quotes and escapes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tokens = try lexOrError("\"a\\\"b\\\\c\"", arena.allocator(), .{});
    try expectKinds(&.{ .quoted, .eof }, tokens);
    try testing.expectEqualStrings("a\"b\\c", tokens[0].text);

    try testing.expectError(error.UnterminatedQuote, lexOrError("\"open", arena.allocator(), .{}));
    try testing.expectError(error.InvalidEscape, lexOrError("\"bad \\n escape\"", arena.allocator(), .{}));
    try testing.expectError(error.NewlineInQuote, lexOrError("\"line\nbreak\"", arena.allocator(), .{}));
}

test "lexer: comment ends literal and hash in quote is text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tokens = try lexOrError("value#comment\nnext", arena.allocator(), .{});
    try expectKinds(&.{ .literal, .literal, .eof }, tokens);
    try testing.expectEqualStrings("value", tokens[0].text);
    try testing.expectEqualStrings("next", tokens[1].text);

    const quoted = try lexOrError("\"x # y\"", arena.allocator(), .{});
    try expectKinds(&.{ .quoted, .eof }, quoted);
    try testing.expectEqualStrings("x # y", quoted[0].text);
}

test "lexer: empty input yields just eof" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tokens = try lexOrError("", arena.allocator(), .{});
    try expectKinds(&.{.eof}, tokens);
}
