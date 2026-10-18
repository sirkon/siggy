//! Error codes, diagnostics, and the diagnostic-printer contract shared by the
//! lexer, the parser, and the schema-guided deserializer.

const std = @import("std");

pub const ParsingError = error{
    // Lexing.
    UnexpectedToken,
    UnterminatedQuote,
    InvalidEscape,
    NewlineInQuote,
    BomPresent,
    LiteralTooLong,

    // Parsing.
    EmptyList,
    MixedListSeparators,
    CommaInDocument,

    // Deserialization.
    BadNumber,
    UnknownVariant,
    UnknownField,
    MissingField,
    DuplicateField,
    EmptyNotAllowed,
    UnsupportedShape,
    ExpectedQuoted,
    MaxDepthExceeded,
    MaxListLenExceeded,

    // Custom decoders and infrastructure.
    Custom,
    OutOfMemory,
};

pub const FileIoError = std.Io.Dir.ReadFileAllocError;

/// Filled by a custom `decode` implementation on failure.
pub const Diagnostic = struct {
    code: ParsingError = error.Custom,
    offset: usize = 0,
    message: []const u8 = "",
};

/// What a printer receives: the diagnostic plus the source it refers to so a
/// renderer can show line/column context.
pub const Diagnostics = struct {
    diagnostic: Diagnostic = .{},
    /// Borrowed from the caller for the duration of the print.
    source: []const u8 = "",
    /// Name shown in rendered diagnostics, e.g. the file path.
    path: []const u8 = "",
};

pub const Printer = *const fn (allocator: std.mem.Allocator, diag: *Diagnostics) anyerror!void;

/// Default printer: render through `higgy` and write to stderr. Scratch memory
/// for the rendered block is released before returning.
pub fn defaultPrinter(allocator: std.mem.Allocator, diag: *Diagnostics) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const text = try @import("siggy/higgy.zig").render(arena.allocator(), diag);
    std.debug.print("{s}", .{text});
}

/// Runs `printer` (or the default) on a diagnostic, using `allocator` for any
/// scratch memory. Printers must not keep a pointer to `diag`.
pub fn print(printer: ?Printer, allocator: std.mem.Allocator, diag: *Diagnostics) void {
    (printer orelse defaultPrinter)(allocator, diag) catch {};
}
