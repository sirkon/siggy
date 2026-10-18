//! Limits enforced while lexing, parsing, and deserializing.

pub const Options = struct {
    /// Longest LITERAL the lexer accepts, in bytes.
    max_literal_len: usize = 4096,
    /// Deepest nesting of blocks the deserializer follows.
    max_depth: usize = 64,
    /// Longest list block the deserializer accepts, in items.
    max_list_len: usize = 1 << 20,
    /// Largest file `parse_file` will read, in bytes.
    max_file_size: usize = 16 << 20,
};
