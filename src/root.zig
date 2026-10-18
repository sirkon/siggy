//! The siggy public entry point.
//!
//! `parser` is the only callable in this file: everything else is data or a
//! type. Diagnostics are rendered by the `higgy` namespace.

const std = @import("std");

const schema = @import("siggy/schema.zig");
const diagnostic = @import("diagnostic.zig");
const options_mod = @import("options.zig");

pub const ParsingError = diagnostic.ParsingError;
pub const FileIoError = diagnostic.FileIoError;
pub const Diagnostic = diagnostic.Diagnostic;
pub const Diagnostics = diagnostic.Diagnostics;
pub const Printer = diagnostic.Printer;
pub const Options = options_mod.Options;

pub const AstNode = @import("siggy/ast.zig").AstNode;
pub const Token = @import("siggy/ast.zig").Token;
pub const TokenKind = @import("siggy/ast.zig").Kind;

/// `higgy` renders diagnostics; it exposes no callables of its own.
pub const higgy = struct {
    pub const Location = @import("siggy/higgy.zig").Location;
};

/// Builds a schema-guided parser for `T`.
pub const parser = schema.parser;

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(@import("parser.zig"));
    std.testing.refAllDecls(@import("siggy/higgy.zig"));
    std.testing.refAllDecls(@import("siggy/lexer.zig"));
    std.testing.refAllDecls(@import("siggy/mask.zig"));
    std.testing.refAllDecls(@import("siggy/schema.zig"));
    std.testing.refAllDecls(@import("siggy/support.zig"));
    _ = @import("tests.zig");
    _ = @import("test.zig");
}
