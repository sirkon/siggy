//! End-to-end tests for the schema-guided parser.

const std = @import("std");
const siggy = @import("root.zig");

const testing = std.testing;

/// Tests that only care about the returned error use a silent printer.
fn silentPrinter(allocator: std.mem.Allocator, diag: *siggy.Diagnostics) anyerror!void {
    _ = allocator;
    _ = diag;
}

/// Custom leaf: `10ms`, `250us`, `2s`.
const Duration = struct {
    nanos: u64,

    pub fn decode(
        self: *Duration,
        source_arena: std.mem.Allocator,
        value_arena: std.mem.Allocator,
        node: siggy.AstNode,
        diag: *siggy.Diagnostic,
    ) !void {
        _ = value_arena;
        const text = switch (node) {
            .literal => |literal| literal,
            else => {
                diag.code = error.Custom;
                diag.message = try source_arena.dupe(u8, "duration must be a literal");
                return error.BadDuration;
            },
        };
        const unit: u64 = if (std.mem.endsWith(u8, text, "ms"))
            1_000_000
        else if (std.mem.endsWith(u8, text, "us"))
            1_000
        else if (std.mem.endsWith(u8, text, "s"))
            1_000_000_000
        else {
            diag.code = error.Custom;
            diag.message = try source_arena.dupe(u8, "duration needs a unit");
            return error.BadDuration;
        };
        const digits = text[0 .. text.len - (if (unit == 1_000_000_000) @as(usize, 1) else 2)];
        self.nanos = std.fmt.parseInt(u64, digits, 10) catch {
            diag.code = error.Custom;
            diag.message = try source_arena.dupe(u8, "duration needs a number");
            return error.BadDuration;
        };
        self.nanos *= unit;
    }

    pub fn encode(self: Duration, allocator: std.mem.Allocator) ![]const u8 {
        return allocator.print("{d}ms", .{self.nanos / 1_000_000});
    }
};

const Color = enum { red, green, blue };

const Shape = union(enum) {
    circle: u32,
    square: struct { side: u32 },
    empty: void,
};

const Plain = union(enum) {
    literal: []const u8,
    tagged: u32,
};

const Nested = struct {
    name: []const u8,
    inner: Inner,
    maybe: ?Inner = null,
};

const Inner = struct {
    value: u32 = 7,
    label: ?[]const u8 = null,
};

const Everything = struct {
    flag: bool,
    small: u8,
    signed: i32,
    big: usize,
    ratio: f64,
    color: Color,
    shape: Shape,
    text: []const u8,
    list: []u32,
    names: [][]const u8,
    table: std.AutoArrayHashMapUnmanaged(u32, []const u8),
    nested: Nested,
    duration: Duration,
    opt: ?[]const u8 = null,
    defaults: Inner = .{},
};

const EverythingParser = siggy.parser(Everything);

const Fixture = struct {
    scratch: std.heap.ArenaAllocator,
    values: std.heap.ArenaAllocator,
    p: EverythingParser = undefined,

    fn init(self: *Fixture) void {
        self.* = .{
            .scratch = std.heap.ArenaAllocator.init(testing.allocator),
            .values = std.heap.ArenaAllocator.init(testing.allocator),
        };
        self.p.init(self.scratch.allocator(), self.values.allocator(), silentPrinter) catch unreachable;
    }

    fn deinit(self: *Fixture) void {
        self.values.deinit();
        self.scratch.deinit();
    }
};

const everything_text =
    \\# fully populated example
    \\flag = true
    \\small = 255
    \\signed = -12
    \\big = 4096
    \\ratio = 1.5
    \\color = green
    \\shape = circle { 3 }
    \\text = "hello \"world\""
    \\list = { 1, 2, 3, }
    \\names = { "alpha" "beta" }
    \\table = { 1 = "one" 2 = "two" }
    \\nested = { name = "n" inner = { value = 9 } }
    \\duration = 10ms
    \\defaults = { }
;

test "siggy: every supported type decodes" {
    var fixture: Fixture = undefined;
    fixture.init();
    defer fixture.deinit();

    const value = try fixture.p.parse(everything_text);
    try testing.expect(value.flag);
    try testing.expectEqual(@as(u8, 255), value.small);
    try testing.expectEqual(@as(i32, -12), value.signed);
    try testing.expectEqual(@as(usize, 4096), value.big);
    try testing.expectEqual(@as(f64, 1.5), value.ratio);
    try testing.expectEqual(Color.green, value.color);
    try testing.expectEqual(Shape{ .circle = 3 }, value.shape);
    try testing.expectEqualStrings("hello \"world\"", value.text);
    try testing.expectEqual(@as(usize, 3), value.list.len);
    try testing.expectEqual(@as(u32, 3), value.list[2]);
    try testing.expectEqualStrings("beta", value.names[1]);
    try testing.expectEqual(@as(usize, 2), value.table.count());
    try testing.expectEqualStrings("two", value.table.get(2).?);
    try testing.expectEqualStrings("n", value.nested.name);
    try testing.expectEqual(@as(u32, 9), value.nested.inner.value);
    try testing.expect(value.nested.maybe == null);
    try testing.expectEqual(@as(u64, 10_000_000), value.duration.nanos);
    try testing.expect(value.opt == null);
    try testing.expectEqual(@as(u32, 7), value.defaults.value);
}

test "siggy: integers accept alternate bases" {
    const T = struct { hex: u32, bin: u8 };
    var values = std.heap.ArenaAllocator.init(testing.allocator);
    defer values.deinit();
    var p: siggy.parser(T) = undefined;
    try p.init(testing.allocator, values.allocator(), silentPrinter);
    const v = try p.parse("hex = 0x1f bin = 0b1010");
    try testing.expectEqual(@as(u32, 31), v.hex);
    try testing.expectEqual(@as(u8, 10), v.bin);
}

test "siggy: enums and void union variants" {
    const T = struct { color: Color, shape: Shape };
    var values = std.heap.ArenaAllocator.init(testing.allocator);
    defer values.deinit();
    var p: siggy.parser(T) = undefined;
    try p.init(testing.allocator, values.allocator(), silentPrinter);

    const v = try p.parse("color = blue shape = empty { }");
    try testing.expectEqual(Color.blue, v.color);
    try testing.expectEqual(Shape.empty, v.shape);

    try testing.expectError(error.UnknownVariant, p.parse("color = purple shape = empty { }"));
}

test "siggy: a non-void literal variant requires a quoted string" {
    const Wrapped = struct { v: Plain };
    var values = std.heap.ArenaAllocator.init(testing.allocator);
    defer values.deinit();
    var p: siggy.parser(Wrapped) = undefined;
    try p.init(testing.allocator, values.allocator(), silentPrinter);

    // The `literal` variant is `[]const u8`, so a bare LITERAL is rejected.
    try testing.expectError(error.ExpectedQuoted, p.parse("v = bare"));

    const tagged = try p.parse("v = tagged { 9 }");
    try testing.expectEqual(Plain{ .tagged = 9 }, tagged.v);
}

test "siggy: Literal never becomes a string" {
    const T = struct { name: []const u8 };
    var values = std.heap.ArenaAllocator.init(testing.allocator);
    defer values.deinit();
    var p: siggy.parser(T) = undefined;
    try p.init(testing.allocator, values.allocator(), silentPrinter);

    try testing.expectError(error.ExpectedQuoted, p.parse("name = my-service"));
    const ok = try p.parse("name = \"my-service\"");
    try testing.expectEqualStrings("my-service", ok.name);
}

test "siggy: strictness for unknown, duplicate, and missing fields" {
    const T = struct { a: u32, b: u32 = 2 };
    var values = std.heap.ArenaAllocator.init(testing.allocator);
    defer values.deinit();
    var p: siggy.parser(T) = undefined;
    try p.init(testing.allocator, values.allocator(), silentPrinter);

    try testing.expectError(error.UnknownField, p.parse("a = 1 c = 2"));
    try testing.expectError(error.DuplicateField, p.parse("a = 1 a = 2"));
    try testing.expectError(error.MissingField, p.parse("b = 1"));
    const v = try p.parse("a = 1");
    try testing.expectEqual(@as(u32, 2), v.b);
}

test "siggy: empty block semantics depend on T" {
    const EmptyOk = struct { a: ?u32, b: u32 = 1 };
    const EmptyStruct = struct { x: u32 };
    const EmptyBad = struct { a: ?EmptyStruct };
    const EmptyWithRequired = struct { a: EmptyStruct };
    const EmptyUnion = union(enum) { a: u32 };

    var values = std.heap.ArenaAllocator.init(testing.allocator);
    defer values.deinit();

    var ok_p: siggy.parser(EmptyOk) = undefined;
    try ok_p.init(testing.allocator, values.allocator(), silentPrinter);
    const ok = try ok_p.parse("a = { }");
    try testing.expect(ok.a == null);
    try testing.expectEqual(@as(u32, 1), ok.b);
    try testing.expectError(error.EmptyNotAllowed, ok_p.parse("a = { } b = { }"));

    // `?T`: an empty block is null.
    var optional_p: siggy.parser(EmptyBad) = undefined;
    try optional_p.init(testing.allocator, values.allocator(), silentPrinter);
    try testing.expect((try optional_p.parse("a = { }")).a == null);

    // A struct inside the empty block still needs every required field.
    var bad_p: siggy.parser(EmptyWithRequired) = undefined;
    try bad_p.init(testing.allocator, values.allocator(), silentPrinter);
    try testing.expectError(error.MissingField, bad_p.parse("a = { }"));

    const HoldsUnion = struct { u: EmptyUnion };
    var union_p: siggy.parser(HoldsUnion) = undefined;
    try union_p.init(testing.allocator, values.allocator(), silentPrinter);
    try testing.expectError(error.EmptyNotAllowed, union_p.parse("u = { }"));
}

test "siggy: lists are homogeneous by T, not by AST shape" {
    const Item = union(enum) { literal: u32, named: struct { v: u32 } };
    const T = struct { items: []Item };
    var values = std.heap.ArenaAllocator.init(testing.allocator);
    defer values.deinit();
    var p: siggy.parser(T) = undefined;
    try p.init(testing.allocator, values.allocator(), silentPrinter);

    const v = try p.parse("items = { 1 named { v = 2 } 3 }");
    try testing.expectEqual(@as(usize, 3), v.items.len);
    try testing.expectEqual(Item{ .literal = 1 }, v.items[0]);
    try testing.expectEqual(Item{ .named = .{ .v = 2 } }, v.items[1]);
}

test "siggy: dictionaries are open and typed" {
    const T = struct { ports: std.AutoArrayHashMapUnmanaged(usize, u32) };
    var values = std.heap.ArenaAllocator.init(testing.allocator);
    defer values.deinit();
    var p: siggy.parser(T) = undefined;
    try p.init(testing.allocator, values.allocator(), silentPrinter);

    const v = try p.parse("ports = { 80 = 1 443 = 2 }");
    try testing.expectEqual(@as(u32, 2), v.ports.get(443).?);

    try testing.expectError(error.BadNumber, p.parse("ports = { http = 1 }"));
    try testing.expectError(error.EmptyNotAllowed, p.parse("ports = { }"));
}

test "siggy: optional blocks detect null before decoding" {
    const Outer = struct { inner: ?Inner };
    var values = std.heap.ArenaAllocator.init(testing.allocator);
    defer values.deinit();
    var p: siggy.parser(Outer) = undefined;
    try p.init(testing.allocator, values.allocator(), silentPrinter);

    const v = try p.parse("inner = { }");
    try testing.expect(v.inner == null);
}

test "siggy: max depth and max list length are enforced" {
    const T = struct { deep: ?Nested };
    var values = std.heap.ArenaAllocator.init(testing.allocator);
    defer values.deinit();
    var p: siggy.parser(T) = undefined;
    try p.init(testing.allocator, values.allocator(), silentPrinter);
    p.options.max_depth = 1;

    try testing.expectError(
        error.MaxDepthExceeded,
        p.parse("deep = { name = \"x\" inner = { } }"),
    );

    const L = struct { xs: []u32 };
    var l_p: siggy.parser(L) = undefined;
    try l_p.init(testing.allocator, values.allocator(), silentPrinter);
    l_p.options.max_list_len = 2;
    try testing.expectError(error.MaxListLenExceeded, l_p.parse("xs = { 1 2 3 }"));
    _ = try l_p.parse("xs = { 1 2 }");
}

test "siggy: custom decode and encode" {
    const T = struct { timeout: Duration };
    var values = std.heap.ArenaAllocator.init(testing.allocator);
    defer values.deinit();
    var p: siggy.parser(T) = undefined;
    try p.init(testing.allocator, values.allocator(), silentPrinter);

    const v = try p.parse("timeout = 250us");
    try testing.expectEqual(@as(u64, 250_000), v.timeout.nanos);
    try testing.expectError(error.Custom, p.parse("timeout = \"250us\""));
    try testing.expectError(error.Custom, p.parse("timeout = 250"));

    const text = p.stringify(v);
    try testing.expectEqualStrings("timeout = 0ms\n", text);
}

test "siggy: custom decode fallback fills a diagnostic" {
    const T = struct {
        d: Bad,

        const Bad = struct {
            pub fn decode(
                self: *@This(),
                source_arena: std.mem.Allocator,
                value_arena: std.mem.Allocator,
                node: siggy.AstNode,
                diag: *siggy.Diagnostic,
            ) !void {
                _ = self;
                _ = source_arena;
                _ = value_arena;
                _ = node;
                _ = diag;
                return error.Nope;
            }

            pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]const u8 {
                _ = self;
                return allocator.dupe(u8, "");
            }
        };
    };

    var values = std.heap.ArenaAllocator.init(testing.allocator);
    defer values.deinit();
    var p: siggy.parser(T) = undefined;
    try p.init(testing.allocator, values.allocator(), silentPrinter);

    try testing.expectError(error.Custom, p.parse("d = x"));
    try testing.expect(p.diagnostic != null);
    try testing.expectEqual(@as(usize, 4), p.diagnostic.?.offset);
}

test "siggy: value survives resetting the source allocator" {
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    var values = std.heap.ArenaAllocator.init(testing.allocator);
    defer values.deinit();

    var p: EverythingParser = undefined;
    try p.init(scratch.allocator(), values.allocator(), silentPrinter);

    const v = try p.parse(everything_text);
    // The parser frees its own scratch before returning; resetting the parent
    // arena proves nothing in the value points into it.
    _ = scratch.reset(.free_all);

    try testing.expectEqualStrings("hello \"world\"", v.text);
    try testing.expectEqualStrings("beta", v.names[1]);
    try testing.expectEqualStrings("n", v.nested.name);
    try testing.expectEqualStrings("two", v.table.get(2).?);
}

test "siggy: stringify round-trips through parse" {
    var values = std.heap.ArenaAllocator.init(testing.allocator);
    defer values.deinit();
    var p: EverythingParser = undefined;
    try p.init(testing.allocator, values.allocator(), silentPrinter);

    const original = try p.parse(everything_text);
    const text = p.stringify(original);
    try testing.expect(text.len > 0);
    const reparsed = try p.parse(text);
    try testing.expectEqualStrings(original.text, reparsed.text);
    try testing.expectEqual(original.color, reparsed.color);
    try testing.expectEqual(original.shape, reparsed.shape);
    try testing.expectEqual(original.list.len, reparsed.list.len);
    try testing.expectEqualStrings(original.table.get(1).?, reparsed.table.get(1).?);
}

test "siggy: parse reports syntax errors and offsets" {
    const T = struct { a: u32 };
    var values = std.heap.ArenaAllocator.init(testing.allocator);
    defer values.deinit();
    var p: siggy.parser(T) = undefined;
    try p.init(testing.allocator, values.allocator(), silentPrinter);

    try testing.expectError(error.CommaInDocument, p.parse("a = { b = 1, c = 2 }"));
    try testing.expectEqual(@as(?usize, 11), if (p.diagnostic) |d| d.offset else null);
    try testing.expectEqual(siggy.ParsingError.CommaInDocument, p.diagnostic.?.code);
}

test "siggy: parse_file reads from disk" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "cpu.cfg", .data = "index_threads_mask = { 0 1 }" });

    const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/cpu.cfg", .{tmp.sub_path});
    defer testing.allocator.free(path);

    var values = std.heap.ArenaAllocator.init(testing.allocator);
    defer values.deinit();
    var p: siggy.parser(@import("siggy/mask.zig").CpuConfig) = undefined;
    try p.init(testing.allocator, values.allocator(), silentPrinter);

    const config = try p.parse_file(path);
    try testing.expectEqual(@as(usize, 2), config.index_threads_mask.len);
    try testing.expectEqual(@as(usize, 0), config.pin_threads_mask.len);

    try testing.expectError(error.FileNotFound, p.parse_file(".zig-cache/tmp/does-not-exist.cfg"));
}

test "siggy: custom printers receive rendered diagnostics" {
    const T = struct { a: u32 };
    const Capture = struct {
        var called: bool = false;
        fn print(allocator: std.mem.Allocator, diag: *siggy.Diagnostics) anyerror!void {
            _ = allocator;
            called = true;
            try testing.expect(diag.path.len == 0);
            try testing.expect(diag.diagnostic.message.len > 0);
        }
    };
    Capture.called = false;

    var values = std.heap.ArenaAllocator.init(testing.allocator);
    defer values.deinit();
    var p: siggy.parser(T) = undefined;
    try p.init(testing.allocator, values.allocator(), Capture.print);
    try testing.expectError(error.UnknownField, p.parse("b = 1"));
    try testing.expect(Capture.called);
}

test "siggy: bundled example file parses" {
    const mask = @import("siggy/mask.zig");
    var values = std.heap.ArenaAllocator.init(testing.allocator);
    defer values.deinit();
    var p: siggy.parser(mask.CpuConfig) = undefined;
    try p.init(testing.allocator, values.allocator(), silentPrinter);

    const config = try p.parse_file("examples/cpu.cfg");
    try testing.expectEqual(@as(usize, 3), config.index_threads_mask.len);
    try testing.expectEqual(mask.MaskItem{ .range = .{ .start = 10, .end = 12 } }, config.index_threads_mask[2]);
    try testing.expectEqual(@as(usize, 4), config.pin_threads_mask.len);
}

test "root: parser is the only public function" {
    const root = siggy;
    try testing.expect(@typeInfo(@TypeOf(root.parser)) == .@"fn");
    try testing.expect(@typeInfo(@TypeOf(root.higgy)) == .type);
    try testing.expect(@typeInfo(@TypeOf(root.ParsingError)) == .type);
    try testing.expect(@typeInfo(@TypeOf(root.Options)) == .type);
    try testing.expect(@typeInfo(@TypeOf(root.Diagnostic)) == .type);
    try testing.expect(@typeInfo(@TypeOf(root.Diagnostics)) == .type);
    try testing.expect(@typeInfo(@TypeOf(root.AstNode)) == .type);
    try testing.expect(@typeInfo(@TypeOf(root.Token)) == .type);
    try testing.expect(@typeInfo(@TypeOf(root.higgy.Location)) == .type);
    try testing.expect(!@hasDecl(root.higgy, "render"));
}
