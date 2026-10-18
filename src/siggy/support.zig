//! Compile-time validation of schema types.
//!
//! `assertSupported(T)` walks `T` recursively and raises
//! `@compileError("unsupported type for siggy")` for anything the
//! deserializer cannot map from the siggy AST.

const std = @import("std");

/// A type is a "leaf" when it maps to a single AST value (Literal, Quoted, or
/// a tagged block) without inspecting blocks generically. Maps and enums with
/// children are not leaves.
pub const LeafKind = enum {
    boolean,
    integer,
    float,
    string,
    enumeration,
    custom,
};

pub fn assertSupported(comptime T: type) void {
    walk(T, &.{}, "top level");
}

fn walk(comptime T: type, comptime seen: []const type, comptime path: []const u8) void {
    switch (@typeInfo(T)) {
        .bool, .int, .comptime_int, .float, .comptime_float, .void => {},
        .optional => |opt| walk(opt.child, seen, path),
        .pointer => |ptr| {
            // `[]const u8` is the string leaf; other slices are lists.
            if (ptr.size != .slice) return unsupported(T, path);
            if (ptr.child == u8) return;
            walk(ptr.child, seen, path);
        },
        .@"struct" => |info| {
            if (isMapType(T)) {
                const kv = mapKV(T);
                if (!isLiteralKey(kv.K)) {
                    @compileError(
                        "unsupported dictionary key type for siggy: " ++ @typeName(kv.K) ++
                            " (keys come from literals: bool, integers, enums, or []const u8)",
                    );
                }
                walk(kv.V, seen, path);
                return;
            }
            if (isCustom(T)) return;
            if (info.is_tuple) return unsupported(T, path);
            if (containsType(seen, T)) return;
            const next = seen ++ &[_]type{T};
            inline for (info.field_types, info.field_names) |field_type, name| {
                _ = name;
                walk(field_type, next, path);
            }
        },
        .@"union" => |info| {
            if (info.tag_type == null) return unsupported(T, path);
            if (containsType(seen, T)) return;
            const next = seen ++ &[_]type{T};
            inline for (info.field_types) |field_type| walk(field_type, next, path);
        },
        .@"enum" => {},
        else => unsupported(T, path),
    }
}

fn unsupported(comptime T: type, comptime path: []const u8) noreturn {
    @compileError("unsupported type for siggy: " ++ @typeName(T) ++ " (at " ++ path ++ ")");
}

pub fn containsType(comptime seen: []const type, comptime T: type) bool {
    for (seen) |s| if (s == T) return true;
    return false;
}

pub fn leafKind(comptime T: type) ?LeafKind {
    return switch (@typeInfo(T)) {
        .bool => .boolean,
        .int, .comptime_int => .integer,
        .float, .comptime_float => .float,
        .@"enum" => .enumeration,
        .@"struct" => if (isCustom(T)) .custom else null,
        .pointer => |ptr| if (ptr.size == .slice and ptr.child == u8) .string else null,
        else => null,
    };
}

/// AutoArrayHashMapUnmanaged(K, V). Recognised structurally so callers may
/// spell it however they like.
pub fn isMapType(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasDecl(T, "KV")) return false;
    const KV: type = @field(T, "KV");
    if (!@hasField(KV, "key") or !@hasField(KV, "value")) return false;
    const info = @typeInfo(T);
    _ = info;
    return @hasField(T, "entries") and
        @hasField(T, "index_header") and
        @hasField(T, "pointer_stability");
}

/// Keys are written as LITERAL tokens, so only types with an unambiguous
/// literal spelling are allowed.
pub fn isLiteralKey(comptime K: type) bool {
    return switch (@typeInfo(K)) {
        .bool, .int, .@"enum" => true,
        .pointer => |ptr| ptr.size == .slice and ptr.child == u8,
        else => false,
    };
}

pub fn mapKV(comptime T: type) struct { K: type, V: type } {
    const KV: type = @field(T, "KV");
    return .{ .K = @FieldType(KV, "key"), .V = @FieldType(KV, "value") };
}

/// Custom leaf types implement `decode`/`encode` with the signatures described
/// in the README.
pub fn isCustom(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasDecl(T, "decode") or !@hasDecl(T, "encode")) return false;

    const decode_info = @typeInfo(@TypeOf(T.decode));
    const encode_info = @typeInfo(@TypeOf(T.encode));
    if (decode_info != .@"fn" or encode_info != .@"fn") return false;

    const decode_params = decode_info.@"fn".param_types;
    const encode_params = encode_info.@"fn".param_types;
    if (decode_params.len < 2 or encode_params.len < 2) return false;
    if (decode_params[0] == null or decode_params[0].? != *T) return false;
    const encode_self = encode_params[0] orelse return false;
    if (!(encode_self == T or encode_self == *const T)) return false;
    return true;
}

test "support: primitives and containers are accepted" {
    const S = struct { a: u32, b: ?[]const u8 };
    comptime assertSupported(S);
    comptime assertSupported(std.AutoArrayHashMapUnmanaged(u32, []const u8));
    comptime assertSupported([]S);
    comptime assertSupported(union(enum) { a: u32, b: S });
    comptime assertSupported([]const u8);
    comptime assertSupported(f64);
}

test "support: recognition helpers" {
    try std.testing.expect(!isMapType([]const u8));
    try std.testing.expect(isMapType(std.AutoArrayHashMapUnmanaged(u32, u8)));
    try std.testing.expectEqual(LeafKind.integer, leafKind(u32).?);
    try std.testing.expectEqual(LeafKind.string, leafKind([]const u8).?);
    try std.testing.expectEqual(@as(?LeafKind, null), leafKind([]u32));
}
