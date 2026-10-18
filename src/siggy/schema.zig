//! Schema-guided parser: maps the siggy AST onto an arbitrary supported Zig
//! type `T`.
//!
//! ```zig
//! const Cpu = siggy.parser(CpuConfig);
//! var p: Cpu = undefined;
//! try p.init(gpa, gpa, null);
//! const config = try p.parse(text);
//! ```
//!
//! `init` takes two allocators:
//!   - `source_allocator`: ephemeral. Holds the token slice, AST, scratch
//!     strings, and diagnostic messages. Everything allocated here is released
//!     before `parse` returns.
//!   - `dst_allocator`: persistent. Owns the returned value, including every
//!     `[]const u8`, slice, map, and custom value. Usually an arena.

const std = @import("std");
const ast = @import("ast.zig");
const ast_parser = @import("../parser.zig");
const diagnostic = @import("../diagnostic.zig");
const options_mod = @import("../options.zig");
const support = @import("support.zig");

pub const ParsingError = diagnostic.ParsingError;
pub const Diagnostic = diagnostic.Diagnostic;
pub const Diagnostics = diagnostic.Diagnostics;
pub const Printer = diagnostic.Printer;
pub const FileIoError = diagnostic.FileIoError;
pub const Options = options_mod.Options;
pub const AstNode = ast.AstNode;

pub fn parser(comptime T: type) type {
    comptime support.assertSupported(T);
    return struct {
        source_allocator: std.mem.Allocator,
        value_allocator: std.mem.Allocator,
        printer: ?Printer = null,
        options: Options = .{},
        /// The last failure. The message is copied into `value_allocator`, so
        /// it stays valid after `parse` returns; it is overwritten on the next
        /// call.
        diagnostic: ?Diagnostic = null,

        const Self = @This();

        pub fn init(
            self: *Self,
            source_allocator: std.mem.Allocator,
            dst_allocator: std.mem.Allocator,
            printer: ?Printer,
        ) !void {
            self.* = .{
                .source_allocator = source_allocator,
                .value_allocator = dst_allocator,
                .printer = printer,
                .options = .{},
                .diagnostic = null,
            };
        }

        pub fn parse(self: *Self, text: []const u8) ParsingError!T {
            return self.run(text, "");
        }

        pub fn parse_file(self: *Self, path: []const u8) (ParsingError || FileIoError)!T {
            var arena = std.heap.ArenaAllocator.init(self.source_allocator);
            defer arena.deinit();
            const text = std.Io.Dir.cwd().readFileAlloc(
                std.Options.debug_io,
                path,
                arena.allocator(),
                .limited(self.options.max_file_size),
            ) catch |err| {
                self.diagnostic = .{ .code = error.Custom, .message = @errorName(err) };
                return err;
            };
            return self.run(text, path);
        }

        /// Encodes `value` back into siggy text. The result is owned by
        /// `dst_allocator`; the caller does not free it. On allocation failure
        /// an empty slice is returned and `diagnostic` is filled.
        pub fn stringify(self: *Self, value: T) []const u8 {
            self.diagnostic = null;
            var encoder = Encoder{ .allocator = self.value_allocator };
            encoder.encodeDocument(T, value) catch |err| {
                self.diagnostic = .{ .code = classify(err), .message = "failed to encode value" };
                return "";
            };
            return encoder.finish() catch {
                self.diagnostic = .{ .code = error.OutOfMemory, .message = "failed to encode value" };
                return "";
            };
        }

        fn run(self: *Self, text: []const u8, path: []const u8) ParsingError!T {
            self.diagnostic = null;

            // Both arenas are ephemeral: the caller never sees the AST.
            var source_arena = std.heap.ArenaAllocator.init(self.source_allocator);
            defer source_arena.deinit();
            var ast_arena = std.heap.ArenaAllocator.init(self.source_allocator);
            defer ast_arena.deinit();

            const parsed = ast_parser.parseDetailed(
                text,
                &source_arena,
                &ast_arena,
                .{ .max_literal_len = self.options.max_literal_len },
            );
            const document = switch (parsed) {
                .err => |diag| {
                    self.diagnostic = self.persist(diag);
                    self.report(diag, text, path);
                    return diag.code;
                },
                .ok => |doc| doc,
            };

            var root = ast.Block{ .document = document };
            var ctx = Decoder{
                .source = source_arena.allocator(),
                .value = self.value_allocator,
                .options = self.options,
            };
            return ctx.decode(T, .{ .block = &root }, 0) catch |err| {
                const diag = ctx.diagnostic orelse Diagnostic{
                    .code = classify(err),
                    .message = @errorName(err),
                };
                self.diagnostic = self.persist(diag);
                self.report(diag, text, path);
                return classify(diag.code);
            };
        }

        /// Copies the diagnostic message out of scratch memory so `diagnostic`
        /// remains readable after the scratch arenas are gone.
        fn persist(self: *Self, diag: Diagnostic) Diagnostic {
            const message = self.value_allocator.dupe(u8, diag.message) catch "";
            return .{ .code = diag.code, .offset = diag.offset, .message = message };
        }

        fn report(self: *Self, diag: Diagnostic, text: []const u8, path: []const u8) void {
            var rendered = Diagnostics{
                .diagnostic = diag,
                .source = text,
                .path = path,
            };
            diagnostic.print(self.printer, self.source_allocator, &rendered);
        }
    };
}

fn classify(err: anyerror) ParsingError {
    inline for (@typeInfo(ParsingError).error_set.error_names.?) |name| {
        if (err == @field(ParsingError, name)) return @field(ParsingError, name);
    }
    return error.Custom;
}

fn isEmptyBlock(node: AstNode) bool {
    return switch (node) {
        .block => |block| block.* == .empty,
        else => false,
    };
}

fn isLeafish(comptime T: type) bool {
    if (support.leafKind(T) != null) return true;
    if (@typeInfo(T) == .optional) return support.leafKind(@typeInfo(T).optional.child) != null;
    return false;
}

/// Finds a struct field or union variant by name.
fn fieldIndex(comptime T: type, name: []const u8) ?std.meta.FieldEnum(T) {
    const names = switch (@typeInfo(T)) {
        .@"struct" => |info| info.field_names,
        .@"union" => |info| info.field_names,
        else => return null,
    };
    inline for (names, 0..) |candidate, i| {
        if (std.mem.eql(u8, candidate, name)) return @fromBackingInt(@intCast(i));
    }
    return null;
}

fn hasVoidVariant(comptime T: type) bool {
    const info = @typeInfo(T).@"union";
    for (info.field_types) |Payload| if (Payload == void) return true;
    return false;
}

fn hasLiteralVariant(comptime T: type) bool {
    const info = @typeInfo(T).@"union";
    inline for (info.field_names, info.field_types) |name, Payload| {
        if (std.mem.eql(u8, name, "literal") and Payload != void) return true;
    }
    return false;
}

/// The variant value for `name` when that variant's payload is `void`.
fn voidVariantValue(comptime T: type, name: []const u8) ?T {
    const info = @typeInfo(T).@"union";
    comptime var i: usize = 0;
    inline while (i < info.field_names.len) : (i += 1) {
        const candidate = info.field_names[i];
        const Payload = info.field_types[i];
        if (Payload == void and std.mem.eql(u8, candidate, name)) {
            return @unionInit(T, candidate, {});
        }
    }
    return null;
}

fn parseIntText(comptime T: type, text: []const u8) ?T {
    const base: u8 = if (std.mem.startsWith(u8, text, "0x") or
        std.mem.startsWith(u8, text, "0X") or
        std.mem.startsWith(u8, text, "0b") or
        std.mem.startsWith(u8, text, "0o"))
        0
    else
        10;
    return std.fmt.parseInt(T, text, base) catch null;
}

const Decoder = struct {
    source: std.mem.Allocator,
    value: std.mem.Allocator,
    options: Options,
    depth: usize = 0,
    diagnostic: ?Diagnostic = null,

    fn fail(self: *Decoder, code: ParsingError, offset: usize, comptime fmt: []const u8, args: anytype) ParsingError {
        const message = self.source.print(fmt, args) catch {
            self.diagnostic = .{ .code = error.OutOfMemory, .offset = offset, .message = "" };
            return error.OutOfMemory;
        };
        self.diagnostic = .{ .code = code, .offset = offset, .message = message };
        return code;
    }

    fn decode(self: *Decoder, comptime T: type, node: AstNode, offset: usize) ParsingError!T {
        const nested = node == .block or node == .tagged;
        if (nested) {
            if (self.depth >= self.options.max_depth) {
                return self.fail(
                    error.MaxDepthExceeded,
                    offset,
                    "nesting exceeds max_depth {d}",
                    .{self.options.max_depth},
                );
            }
            self.depth += 1;
        }
        defer if (nested) {
            self.depth -= 1;
        };
        return self.decodeInner(T, node, offset);
    }

    fn decodeInner(self: *Decoder, comptime T: type, node: AstNode, offset: usize) ParsingError!T {
        if (comptime T == []const u8) return self.decodeString(node, offset);
        if (comptime support.isCustom(T)) return self.decodeCustom(T, node, offset);

        switch (@typeInfo(T)) {
            .bool, .int, .float, .@"enum" => return self.decodeLeaf(T, node, offset),
            .optional => |optional| {
                if (isEmptyBlock(node)) return null;
                return @as(T, try self.decodeInner(optional.child, node, offset));
            },
            .pointer => |pointer| {
                if (pointer.size != .slice) {
                    return self.fail(error.UnsupportedShape, offset, "pointer type {s} is not a list", .{@typeName(T)});
                }
                return self.decodeList(pointer.child, node, offset);
            },
            .@"struct" => |info| {
                if (info.is_tuple) {
                    return self.fail(error.UnsupportedShape, offset, "tuples are not supported ({s})", .{@typeName(T)});
                }
                if (comptime support.isMapType(T)) return self.decodeMap(T, node, offset);
                return self.decodeStruct(T, node, offset);
            },
            .@"union" => |info| {
                if (info.tag_type == null) {
                    return self.fail(error.UnsupportedShape, offset, "untagged union {s} is not supported", .{@typeName(T)});
                }
                return self.decodeUnion(T, node, offset);
            },
            else => return self.fail(error.UnsupportedShape, offset, "cannot decode {s}", .{@typeName(T)}),
        }
    }

    fn decodeString(self: *Decoder, node: AstNode, offset: usize) ParsingError![]const u8 {
        return switch (node) {
            .quoted => |text| self.value.dupe(u8, text) catch {
                return self.fail(error.OutOfMemory, offset, "out of memory", .{});
            },
            .literal => |text| self.fail(
                error.ExpectedQuoted,
                offset,
                "expected a quoted string for '{s}', e.g. \"{s}\"",
                .{ text, text },
            ),
            .block => |block| switch (block.*) {
                .empty => self.fail(error.EmptyNotAllowed, offset, "empty block cannot be decoded as a string", .{}),
                else => self.fail(error.UnsupportedShape, offset, "block cannot be decoded as a string", .{}),
            },
            .tagged => self.fail(error.UnsupportedShape, offset, "tagged block cannot be decoded as a string", .{}),
        };
    }

    fn decodeLeaf(self: *Decoder, comptime T: type, node: AstNode, offset: usize) ParsingError!T {
        const text = switch (node) {
            .literal => |literal| literal,
            .quoted => return self.fail(
                error.UnsupportedShape,
                offset,
                "quoted value cannot be decoded as {s}",
                .{@typeName(T)},
            ),
            .block => |block| switch (block.*) {
                .empty => return self.fail(
                    error.EmptyNotAllowed,
                    offset,
                    "empty block cannot be decoded as {s}",
                    .{@typeName(T)},
                ),
                else => return self.fail(
                    error.UnsupportedShape,
                    offset,
                    "block cannot be decoded as {s}",
                    .{@typeName(T)},
                ),
            },
            .tagged => return self.fail(
                error.UnsupportedShape,
                offset,
                "tagged block cannot be decoded as {s}",
                .{@typeName(T)},
            ),
        };

        return switch (@typeInfo(T)) {
            .bool => std.mem.eql(u8, text, "true") or
                return self.fail(error.BadNumber, offset, "expected true or false, found '{s}'", .{text}),
            .int => parseIntText(T, text) orelse
                return self.fail(error.BadNumber, offset, "invalid integer '{s}' for {s}", .{ text, @typeName(T) }),
            .float => std.fmt.parseFloat(T, text) catch
                return self.fail(error.BadNumber, offset, "invalid float '{s}' for {s}", .{ text, @typeName(T) }),
            .@"enum" => std.meta.stringToEnum(T, text) orelse
                return self.fail(error.UnknownVariant, offset, "unknown variant '{s}' for {s}", .{ text, @typeName(T) }),
            else => return self.fail(error.UnsupportedShape, offset, "cannot decode {s}", .{@typeName(T)}),
        };
    }

    fn decodeList(self: *Decoder, comptime T: type, node: AstNode, offset: usize) ParsingError![]T {
        const block = switch (node) {
            .block => |block| block,
            else => return self.fail(error.UnsupportedShape, offset, "expected a list block for {s}", .{@typeName(T)}),
        };
        switch (block.*) {
            .empty => return self.value.alloc(T, 0) catch {
                return self.fail(error.OutOfMemory, offset, "out of memory", .{});
            },
            .document => return self.fail(
                error.UnsupportedShape,
                offset,
                "document block cannot be decoded as {s}",
                .{@typeName(T)},
            ),
            .list => |items| {
                if (items.len > self.options.max_list_len) {
                    return self.fail(
                        error.MaxListLenExceeded,
                        offset,
                        "list has {d} items, max_list_len is {d}",
                        .{ items.len, self.options.max_list_len },
                    );
                }
                // Must be mutable: the deserializer fills it element by element.
                const out = self.value.alloc(T, items.len) catch {
                    return self.fail(error.OutOfMemory, offset, "out of memory", .{});
                };
                for (items, 0..) |item, i| out[i] = try self.decode(T, item, offset);
                return out;
            },
        }
    }

    fn decodeMap(self: *Decoder, comptime T: type, node: AstNode, offset: usize) ParsingError!T {
        const kv = support.mapKV(T);
        const block = switch (node) {
            .block => |block| block,
            else => return self.fail(error.UnsupportedShape, offset, "expected a document block for {s}", .{@typeName(T)}),
        };

        var out: T = .empty;
        switch (block.*) {
            // Mapping table: `Block.empty` is only meaningful for optionals,
            // structs, and lists. A dictionary needs at least one key.
            .empty => return self.fail(
                error.EmptyNotAllowed,
                offset,
                "empty block cannot be decoded as a dictionary; omit the field or use an optional",
                .{},
            ),
            .list => return self.fail(error.UnsupportedShape, offset, "list block cannot be decoded as a dictionary", .{}),
            .document => |assigns| {
                for (assigns) |assign| {
                    const key = try self.decodeMapKey(kv.K, assign.key, assign.offset);
                    const value = try self.decode(kv.V, assign.value, assign.value_offset);
                    out.put(self.value, key, value) catch {
                        return self.fail(error.OutOfMemory, assign.offset, "out of memory", .{});
                    };
                }
                return out;
            },
        }
    }

    fn decodeMapKey(self: *Decoder, comptime K: type, text: []const u8, offset: usize) ParsingError!K {
        if (comptime K == []const u8) {
            return self.value.dupe(u8, text) catch {
                return self.fail(error.OutOfMemory, offset, "out of memory", .{});
            };
        }
        return switch (@typeInfo(K)) {
            .bool, .int, .@"enum" => self.decodeLeaf(K, .{ .literal = text }, offset),
            else => self.fail(
                error.UnsupportedShape,
                offset,
                "dictionary keys must be literals, found {s}",
                .{@typeName(K)},
            ),
        };
    }

    fn decodeStruct(self: *Decoder, comptime T: type, node: AstNode, offset: usize) ParsingError!T {
        const info = @typeInfo(T).@"struct";
        const field_count = info.field_names.len;

        const block = switch (node) {
            .block => |block| block,
            else => return self.fail(error.UnsupportedShape, offset, "expected a document block for {s}", .{@typeName(T)}),
        };

        var out: T = undefined;
        var seen: [field_count]bool = @splat(false);

        switch (block.*) {
            .list => return self.fail(error.UnsupportedShape, offset, "list block cannot be decoded as {s}", .{@typeName(T)}),
            .document => |assigns| {
                for (assigns) |assign| {
                    const tag = fieldIndex(T, assign.key) orelse
                        return self.fail(error.UnknownField, assign.offset, "unknown field '{s}' in {s}", .{ assign.key, @typeName(T) });
                    const index = @backingInt(tag);
                    if (seen[index]) {
                        return self.fail(error.DuplicateField, assign.offset, "duplicate field '{s}' in {s}", .{ assign.key, @typeName(T) });
                    }
                    seen[index] = true;
                    switch (tag) {
                        inline else => |active| {
                            const name = @tagName(active);
                            @field(out, name) = try self.decode(@FieldType(T, name), assign.value, assign.value_offset);
                        },
                    }
                }
            },
            // `{ }` for a struct: allowed only when every field can be omitted.
            .empty => {},
        }

        inline for (info.field_names, info.field_types, info.field_attrs, 0..) |name, FieldType, attrs, i| {
            if (!seen[i]) {
                if (attrs.defaultValue(FieldType)) |default| {
                    @field(out, name) = default;
                } else if (@typeInfo(FieldType) == .optional) {
                    @field(out, name) = null;
                } else {
                    return self.fail(error.MissingField, offset, "missing field '{s}' in {s}", .{ name, @typeName(T) });
                }
            }
        }

        return out;
    }

    fn decodeUnion(self: *Decoder, comptime T: type, node: AstNode, offset: usize) ParsingError!T {
        switch (node) {
            // Literal -> union: a void variant with this name wins, then a
            // non-void variant named `literal`.
            .literal => |text| {
                if (comptime hasVoidVariant(T)) {
                    if (voidVariantValue(T, text)) |value| return value;
                }
                if (comptime hasLiteralVariant(T)) {
                    return self.decodeLiteralVariant(T, text, offset);
                }
                return self.fail(
                    error.UnknownVariant,
                    offset,
                    "unknown variant '{s}' for {s}",
                    .{ text, @typeName(T) },
                );
            },
            .tagged => |tagged| {
                const tag = fieldIndex(T, tagged.tag) orelse return self.fail(
                    error.UnknownVariant,
                    tagged.offset,
                    "unknown variant '{s}' for {s}",
                    .{ tagged.tag, @typeName(T) },
                );
                switch (tag) {
                    inline else => |active| {
                        const name = @tagName(active);
                        const Payload = @FieldType(T, name);
                        if (comptime Payload == void) {
                            if (!isEmptyBlock(.{ .block = tagged.block })) {
                                return self.fail(
                                    error.UnsupportedShape,
                                    tagged.offset,
                                    "variant '{s}' takes no payload, expected '{{ }}'",
                                    .{name},
                                );
                            }
                            return @unionInit(T, name, {});
                        }
                        const inner = taggedPayloadNode(Payload, tagged.block);
                        const payload = try self.decode(Payload, inner, tagged.offset);
                        return @unionInit(T, name, payload);
                    },
                }
            },
            .quoted => return self.fail(
                error.UnsupportedShape,
                offset,
                "quoted value cannot be decoded as {s}",
                .{@typeName(T)},
            ),
            .block => |block| switch (block.*) {
                .empty => return self.fail(error.EmptyNotAllowed, offset, "empty block cannot be decoded as {s}", .{@typeName(T)}),
                else => return self.fail(error.UnsupportedShape, offset, "block cannot be decoded as {s}", .{@typeName(T)}),
            },
        }
    }

    fn decodeLiteralVariant(self: *Decoder, comptime T: type, text: []const u8, offset: usize) ParsingError!T {
        const info = @typeInfo(T).@"union";
        comptime var i: usize = 0;
        inline while (i < info.field_names.len) : (i += 1) {
            const name = info.field_names[i];
            const Payload = info.field_types[i];
            if (Payload != void and std.mem.eql(u8, name, "literal")) {
                const payload = try self.decode(Payload, .{ .literal = text }, offset);
                return @unionInit(T, name, payload);
            }
        }
        return self.fail(error.UnknownVariant, offset, "unknown variant '{s}' for {s}", .{ text, @typeName(T) });
    }

    fn decodeCustom(self: *Decoder, comptime T: type, node: AstNode, offset: usize) ParsingError!T {
        const self_ptr = self.value.create(T) catch {
            return self.fail(error.OutOfMemory, offset, "out of memory", .{});
        };
        var local = Diagnostic{ .code = error.Custom, .offset = offset, .message = "" };
        T.decode(self_ptr, self.source, self.value, node, &local) catch |err| {
            if (local.message.len == 0) {
                local.message = self.source.dupe(u8, @errorName(err)) catch "";
                if (local.code == error.Custom and local.message.len == @errorName(err).len) {
                    local.code = classify(err);
                }
            }
            self.diagnostic = local;
            return classify(local.code);
        };
        return self_ptr.*;
    }
};

/// A tagged payload that is a leaf (`tag { value }`) is unwrapped, everything
/// else receives the block itself (`tag { a = 1 }`).
fn taggedPayloadNode(comptime Payload: type, block: *ast.Block) AstNode {
    if (isLeafish(Payload)) {
        switch (block.*) {
            .list => |items| if (items.len == 1) return items[0],
            .empty => return .{ .block = block },
            else => {},
        }
    }
    return .{ .block = block };
}

/// `null` optional values are omitted from the output: absence and `null` are
/// the same thing in siggy.
fn isSkipped(comptime FieldType: type, field: FieldType) bool {
    if (comptime @typeInfo(FieldType) == .optional) return field == null;
    return false;
}

const Encoder = struct {
    allocator: std.mem.Allocator,
    out: ?std.Io.Writer.Allocating = null,

    fn writer(self: *Encoder) *std.Io.Writer {
        if (self.out == null) self.out = .init(self.allocator);
        return &self.out.?.writer;
    }

    fn finish(self: *Encoder) ![]const u8 {
        _ = self.writer();
        return self.out.?.toOwnedSlice();
    }

    fn encodeDocument(self: *Encoder, comptime T: type, value: T) anyerror!void {
        if (comptime T == []const u8 or support.leafKind(T) != null) {
            return self.encodeValue(T, value);
        }
        switch (@typeInfo(T)) {
            .@"struct" => |info| {
                if (comptime support.isMapType(T)) {
                    const kv = support.mapKV(T);
                    var it = value.iterator();
                    while (it.next()) |entry| {
                        try self.encodeMapKey(kv.K, entry.key_ptr.*);
                        try self.writer().writeAll(" = ");
                        try self.encodeValue(kv.V, entry.value_ptr.*);
                        try self.writer().writeByte('\n');
                    }
                    return;
                }
                inline for (info.field_names, info.field_types) |name, FieldType| {
                    const field = @field(value, name);
                    if (isSkipped(FieldType, field)) {
                        // Omitted: absence and null are the same in siggy.
                    } else {
                        try self.encodeField(name, FieldType, field);
                        try self.writer().writeByte('\n');
                    }
                }
                return;
            },
            else => return self.encodeValue(T, value),
        }
    }

    fn encodeField(self: *Encoder, comptime name: []const u8, comptime FieldType: type, field: FieldType) anyerror!void {
        try self.writer().writeAll(name);
        try self.writer().writeAll(" = ");
        try self.encodeValue(FieldType, field);
    }

    fn encodeMapKey(self: *Encoder, comptime K: type, key: K) anyerror!void {
        if (comptime K == []const u8) return self.writer().writeAll(key);
        return self.encodeLeaf(K, key);
    }

    fn encodeValue(self: *Encoder, comptime T: type, value: T) anyerror!void {
        if (comptime T == []const u8) return self.writeQuoted(value);
        if (comptime support.isCustom(T)) return self.encodeCustom(T, value);

        switch (@typeInfo(T)) {
            .bool, .int, .float, .@"enum" => return self.encodeLeaf(T, value),
            .optional => |optional| {
                if (value) |inner| return self.encodeValue(optional.child, inner);
                return self.writer().writeAll("{ }");
            },
            .pointer => |pointer| {
                if (pointer.size != .slice) return error.UnsupportedShape;
                return self.encodeList(pointer.child, value);
            },
            .@"struct" => |info| {
                if (info.is_tuple) return error.UnsupportedShape;
                if (comptime support.isMapType(T)) {
                    if (value.count() == 0) return self.writer().writeAll("{ }");
                    const kv = support.mapKV(T);
                    try self.writer().writeAll("{ ");
                    var it = value.iterator();
                    while (it.next()) |entry| {
                        try self.encodeMapKey(kv.K, entry.key_ptr.*);
                        try self.writer().writeAll(" = ");
                        try self.encodeValue(kv.V, entry.value_ptr.*);
                        try self.writer().writeByte(' ');
                    }
                    return self.writer().writeByte('}');
                }
                if (info.field_names.len == 0) return self.writer().writeAll("{ }");
                try self.writer().writeAll("{ ");
                inline for (info.field_names, info.field_types) |name, FieldType| {
                    const field = @field(value, name);
                    if (isSkipped(FieldType, field)) {
                        // Omitted: absence and null are the same in siggy.
                    } else {
                        try self.encodeField(name, FieldType, field);
                        try self.writer().writeByte(' ');
                    }
                }
                return self.writer().writeByte('}');
            },
            .@"union" => {
                const info = @typeInfo(T).@"union";
                if (info.tag_type == null) return error.UnsupportedShape;
                switch (value) {
                    inline else => |payload, active| {
                        const name = @tagName(active);
                        const Payload = @TypeOf(payload);
                        if (comptime Payload == void) return self.writer().writeAll(name);
                        // A non-void `literal` variant is written bare so it
                        // reads back through the Literal mapping rule.
                        if (comptime std.mem.eql(u8, name, "literal")) {
                            return self.encodeValue(Payload, payload);
                        }
                        try self.writer().writeAll(name);
                        try self.writer().writeByte(' ');
                        if (comptime isLeafish(Payload)) {
                            // Tagged leaf payloads use the `tag { value }`
                            // form, the only tagged shape the grammar allows.
                            try self.writer().writeAll("{ ");
                            try self.encodeValue(Payload, payload);
                            return self.writer().writeAll(" }");
                        }
                        return self.encodeValue(Payload, payload);
                    },
                }
            },
            else => return error.UnsupportedShape,
        }
    }

    fn encodeList(self: *Encoder, comptime T: type, items: []const T) anyerror!void {
        if (items.len == 0) return self.writer().writeAll("{ }");
        try self.writer().writeAll("{ ");
        for (items, 0..) |item, i| {
            if (i != 0) try self.writer().writeByte(' ');
            try self.encodeValue(T, item);
        }
        return self.writer().writeByte('}');
    }

    fn encodeLeaf(self: *Encoder, comptime T: type, value: T) anyerror!void {
        switch (@typeInfo(T)) {
            .bool => return self.writer().writeAll(if (value) "true" else "false"),
            .int => return self.writer().print("{d}", .{value}),
            .float => return self.writer().print("{d}", .{value}),
            .@"enum" => return self.writer().writeAll(@tagName(value)),
            else => return error.UnsupportedShape,
        }
    }

    fn writeQuoted(self: *Encoder, text: []const u8) anyerror!void {
        const w = self.writer();
        try w.writeByte('"');
        for (text) |c| {
            if (c == '"' or c == '\\') try w.writeByte('\\');
            try w.writeByte(c);
        }
        return w.writeByte('"');
    }

    fn encodeCustom(self: *Encoder, comptime T: type, value: T) anyerror!void {
        const params = @typeInfo(@TypeOf(T.encode)).@"fn".param_types;
        const by_pointer = params.len > 0 and params[0] == *const T;
        const text = if (by_pointer)
            T.encode(&value, self.allocator)
        else
            T.encode(value, self.allocator);
        const encoded = try text;
        try self.writer().writeAll(encoded);
    }
};
