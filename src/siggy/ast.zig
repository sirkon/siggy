//! AST produced by the recursive-descent parser, plus the node type handed to
//! custom `decode` implementations.

const std = @import("std");

pub const Value = union(enum) {
    /// Raw literal bytes. LITERAL has no escapes, so the bytes are final.
    literal: []const u8,
    /// Decoded quoted bytes: escapes resolved by the lexer.
    quoted: []const u8,
    block: *Block,
    tagged: Tagged,

    pub const Tagged = struct {
        tag: []const u8,
        block: *Block,
        /// Offset of the tag token in the source, for diagnostics.
        offset: usize = 0,
    };
};

pub const Block = union(enum) {
    document: []Assign,
    list: []Value,
    /// `{ }`: the parser deliberately does not interpret this; the
    /// deserializer decides whether it means an empty list, an empty struct,
    /// `null`, or an error.
    empty: void,
};

pub const Assign = struct {
    key: []const u8,
    value: Value,
    /// Offset of the key token in the source, for diagnostics.
    offset: usize = 0,
    /// Offset of the first token of the value in the source.
    value_offset: usize = 0,
};

pub const Document = []Assign;

/// The node a custom `decode` receives.
pub const AstNode = Value;

pub const Kind = enum {
    assign,
    start,
    end,
    comma,
    literal,
    quoted,
    eof,
};

pub const Token = struct {
    kind: Kind,
    /// For `.quoted`, the decoded payload; for everything else, the raw
    /// source slice.
    text: []const u8,
    offset: usize,
};

test {
    std.testing.refAllDecls(@This());
}
