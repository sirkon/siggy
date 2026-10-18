//! `higgy`: the single diagnostic renderer for siggy.
//!
//! Output is a self-contained, human-readable block:
//!
//! ```
//! error[UnknownField]: examples/cpu.cfg:3:9: unknown field 'foo'
//!    3 | index_threads_mask = { foo }
//!      |                       ^^^
//! ```

const std = @import("std");
const diagnostic = @import("../diagnostic.zig");

pub const CaretSpan = 3;

pub fn render(allocator: std.mem.Allocator, diag: *diagnostic.Diagnostics) ![]const u8 {
    const d = diag.diagnostic;
    const location = locate(diag.source, d.offset);

    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    const w = &out.writer;

    if (diag.path.len == 0) {
        try w.print(
            "error[{s}]: {d}:{d}: {s}\n",
            .{ @errorName(d.code), location.line, location.column, d.message },
        );
    } else {
        try w.print(
            "error[{s}]: {s}:{d}:{d}: {s}\n",
            .{ @errorName(d.code), diag.path, location.line, location.column, d.message },
        );
    }

    if (location.text.len != 0 or diag.source.len != 0) {
        try w.print("{d: >4} | ", .{location.line});
        try w.writeAll(location.text);
        try w.writeByte('\n');

        try w.writeAll("     | ");
        try w.splatByteAll(' ', location.column - 1);
        try w.splatByteAll('^', location.caret_len);
        try w.writeByte('\n');
    }

    return out.toOwnedSlice();
}

pub const Location = struct {
    /// 1-based line number.
    line: usize,
    /// 1-based column, in bytes.
    column: usize,
    /// The full text of the offending line, without its line terminator.
    text: []const u8,
    /// Width of the caret underline.
    caret_len: usize,
};

pub fn locate(source: []const u8, offset: usize) Location {
    const clamped = @min(offset, source.len);
    var line: usize = 1;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i < clamped) : (i += 1) {
        if (source[i] == '\n' and i + 1 <= clamped) {
            line += 1;
            line_start = i + 1;
        }
    }

    var line_end = line_start;
    while (line_end < source.len and source[line_end] != '\n' and source[line_end] != '\r') {
        line_end += 1;
    }

    var text = source[line_start..line_end];
    // Strip a BOM so the caret column stays meaningful.
    if (line == 1 and std.mem.startsWith(u8, text, "\xEF\xBB\xBF")) text = text[3..];

    return .{
        .line = line,
        .column = clamped - line_start + 1,
        .text = text,
        .caret_len = tokenWidth(source, clamped),
    };
}

fn tokenWidth(source: []const u8, offset: usize) usize {
    if (offset >= source.len) return CaretSpan;
    const c = source[offset];
    if (c == '=' or c == '{' or c == '}' or c == ',' or c == '"' or c == '#' or c <= 32) return 1;

    var end = offset;
    while (end < source.len) : (end += 1) {
        const b = source[end];
        if (b <= 32 or b == '=' or b == '{' or b == '}' or b == ',' or b == '"' or b == '#') break;
    }
    return end - offset;
}

const testing = std.testing;

fn renderToBuf(arena: *std.heap.ArenaAllocator, source: []const u8, code: diagnostic.ParsingError, offset: usize, message: []const u8) ![]const u8 {
    var diag = diagnostic.Diagnostics{
        .diagnostic = .{ .code = code, .offset = offset, .message = message },
        .source = source,
        .path = "test.cfg",
    };
    return render(arena.allocator(), &diag);
}

test "higgy: golden diagnostic block" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "a = 1\nb = { c = 1, d = 2 }\n";
    const text = try renderToBuf(&arena, source, error.CommaInDocument, 17, "comma is not allowed inside a document block");
    try testing.expectEqualStrings(
        \\error[CommaInDocument]: test.cfg:2:12: comma is not allowed inside a document block
        \\   2 | b = { c = 1, d = 2 }
        \\     |            ^
        \\
    , text);
}

test "higgy: carets cover the token" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "name = my-service\n";
    const text = try renderToBuf(&arena, source, error.ExpectedQuoted, 7, "expected a quoted string");
    try testing.expectEqualStrings(
        \\error[ExpectedQuoted]: test.cfg:1:8: expected a quoted string
        \\   1 | name = my-service
        \\     |        ^^^^^^^^^^
        \\
    , text);
}

test "higgy: offset past the end clamps to the last line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const text = try renderToBuf(&arena, "a = 1\n", error.UnexpectedToken, 999, "expected '}'");
    try testing.expectEqualStrings(
        \\error[UnexpectedToken]: test.cfg:2:1: expected '}'
        \\   2 | 
        \\     | ^^^
        \\
    , text);
}

test "higgy: crlf source renders without the carriage return" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const text = try renderToBuf(&arena, "a = 1\r\nb = 2\r\n", error.UnexpectedToken, 9, "bad token");
    try testing.expectEqualStrings(
        \\error[UnexpectedToken]: test.cfg:2:3: bad token
        \\   2 | b = 2
        \\     |   ^
        \\
    , text);
}

test "higgy: locates lines and columns" {
    const source = "one\ntwo\nthree";
    const loc = locate(source, 4);
    try testing.expectEqual(@as(usize, 2), loc.line);
    try testing.expectEqual(@as(usize, 1), loc.column);
    try testing.expectEqualStrings("two", loc.text);
}
