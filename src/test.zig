//! Round-trip tests for the deployment `Config` shape: defaults, random
//! values, and hand-written text.

const std = @import("std");
const siggy = @import("root.zig");

const testing = std.testing;

fn silentPrinter(allocator: std.mem.Allocator, diag: *siggy.Diagnostics) anyerror!void {
    _ = allocator;
    _ = diag;
}

const Config = struct {
    /// Server expo params.
    bind: []const u8 = "localhost",
    port: u16 = 60006,

    /// How many front threads and how they are bound into CPU cores.
    fronts: u16 = 2,
    front_cores: CoresMask = .{ .cores = &.{ 2, 3 } },

    /// How many index threads and core distribution as well.
    indexes: u16 = 4,
    index_cores: CoresMask = .{ .cores = &.{ 4, 5, 6, 7 } },

    /// How many "elephant" threads for heavy synchronous processing. With
    /// optional CPU affinity cause these things are meant to be interacted
    /// rarely, the cost of cache misses is miniscule compared to their
    /// workload.
    elephants: u16 = 1,

    /// Server internal params.
    host_index: u16 = 0,
    logging: Logging = .{ .pretty = .dark },
    queue_depth: u32 = 4096,
    init_timeout_sec: u32 = 8,
    shutdown_timeout_sec: u32 = 8,
    cross_task_slots: u32 = 4096,
    accept_backlog: u32 = 1024,
    sqpoll_threads: u32 = 1,
};

/// A set of CPU cores written as `{ 0 1 2 4..9 }`. Ranges are inclusive and
/// the mask is normalized to a sorted, duplicate-free list.
const CoresMask = struct {
    cores: []const u16,

    fn badMask(
        diag: *siggy.Diagnostic,
        allocator: std.mem.Allocator,
        comptime fmt: []const u8,
        args: anytype,
    ) siggy.ParsingError {
        diag.code = error.Custom;
        diag.message = std.fmt.allocPrint(allocator, fmt, args) catch "";
        return error.Custom;
    }

    fn parseCore(text: []const u8) ?u16 {
        if (text.len == 0) return null;
        return std.fmt.parseInt(u16, text, 10) catch null;
    }

    pub fn decode(
        self: *CoresMask,
        source_arena: std.mem.Allocator,
        value_arena: std.mem.Allocator,
        node: siggy.AstNode,
        diag: *siggy.Diagnostic,
    ) !void {
        const items = switch (node) {
            .block => |block| switch (block.*) {
                .empty => {
                    self.cores = &.{};
                    return;
                },
                .list => |items| items,
                .document => return badMask(
                    diag,
                    source_arena,
                    "core mask expects a list such as '{{ 0 1 4..9 }}'",
                    .{},
                ),
            },
            else => return badMask(
                diag,
                source_arena,
                "core mask expects a list such as '{{ 0 1 4..9 }}'",
                .{},
            ),
        };

        var cores: std.ArrayList(u16) = .empty;
        for (items) |item| {
            const text = switch (item) {
                .literal => |literal| literal,
                else => return badMask(
                    diag,
                    source_arena,
                    "core mask items are numbers or ranges (start..end)",
                    .{},
                ),
            };
            if (std.mem.indexOf(u8, text, "..")) |dots| {
                const start = parseCore(text[0..dots]) orelse return badMask(
                    diag,
                    source_arena,
                    "invalid range start '{s}'",
                    .{text},
                );
                const end = parseCore(text[dots + 2 ..]) orelse return badMask(
                    diag,
                    source_arena,
                    "invalid range end '{s}'",
                    .{text},
                );
                if (start > end) return badMask(
                    diag,
                    source_arena,
                    "range '{s}' has start {d} after end {d}",
                    .{ text, start, end },
                );
                var core = start;
                while (true) : (core += 1) {
                    cores.append(source_arena, core) catch return error.OutOfMemory;
                    if (core == end) break;
                }
            } else {
                const core = parseCore(text) orelse return badMask(
                    diag,
                    source_arena,
                    "invalid core '{s}', expected 0..65535",
                    .{text},
                );
                cores.append(source_arena, core) catch return error.OutOfMemory;
            }
        }

        std.mem.sort(u16, cores.items, {}, std.sort.asc(u16));
        var unique: usize = 0;
        for (cores.items) |core| {
            if (unique == 0 or cores.items[unique - 1] != core) {
                cores.items[unique] = core;
                unique += 1;
            }
        }
        self.cores = value_arena.dupe(u16, cores.items[0..unique]) catch return error.OutOfMemory;
    }

    pub fn encode(self: CoresMask, allocator: std.mem.Allocator) ![]const u8 {
        const sorted = try allocator.dupe(u16, self.cores);
        std.mem.sort(u16, sorted, {}, std.sort.asc(u16));

        var out: std.Io.Writer.Allocating = .init(allocator);
        var i: usize = 0;
        while (i < sorted.len) {
            var j = i;
            while (j + 1 < sorted.len and
                @as(u32, sorted[j + 1]) == @as(u32, sorted[j]) + 1)
            {
                j += 1;
            }
            if (j - i < 3) {
                var k = i;
                while (k <= j) : (k += 1) try out.writer.print(" {d}", .{sorted[k]});
            } else {
                try out.writer.print(" {d}..{d}", .{ sorted[i], sorted[j] });
            }
            i = j + 1;
        }
        try out.writer.writeAll(" }");
        if (sorted.len == 0) {
            return allocator.dupe(u8, "{ }");
        }
        const body = try out.toOwnedSlice();
        return std.fmt.allocPrint(allocator, "{{{s}", .{body});
    }
};

const Logging = union(enum) {
    pretty: enum { light, dark, flat },
    json: void,
    file: []const u8,
};

const ConfigParser = siggy.parser(Config);

const Fixture = struct {
    scratch: std.heap.ArenaAllocator,
    values: std.heap.ArenaAllocator,
    p: ConfigParser = undefined,

    fn init() Fixture {
        return .{
            .scratch = std.heap.ArenaAllocator.init(testing.allocator),
            .values = std.heap.ArenaAllocator.init(testing.allocator),
        };
    }

    fn start(self: *Fixture) !void {
        try self.p.init(self.scratch.allocator(), self.values.allocator(), silentPrinter);
    }

    fn deinit(self: *Fixture) void {
        self.values.deinit();
        self.scratch.deinit();
    }
};

test "config: round robin with default values" {
    var fixture = Fixture.init();
    defer fixture.deinit();
    try fixture.start();

    const original: Config = .{};
    try testing.expectEqualSlices(u16, &.{ 2, 3 }, original.front_cores.cores);
    try testing.expectEqualSlices(u16, &.{ 4, 5, 6, 7 }, original.index_cores.cores);

    const text = fixture.p.stringify(original);
    try testing.expect(text.len > 0);

    const decoded = try fixture.p.parse(text);
    try testing.expectEqualDeep(original, decoded);
    try testing.expectEqualStrings("localhost", decoded.bind);
    try testing.expectEqual(@as(u16, 60006), decoded.port);
    try testing.expectEqual(Logging{ .pretty = .dark }, decoded.logging);
}

fn randomString(rng: std.Random, allocator: std.mem.Allocator, len: usize) ![]const u8 {
    const buffer = try allocator.alloc(u8, len);
    for (buffer) |*byte| byte.* = 'a' + rng.intRangeAtMost(u8, 0, 25);
    return buffer;
}

fn randomMask(rng: std.Random, allocator: std.mem.Allocator) !CoresMask {
    const cores = try allocator.alloc(u16, rng.intRangeAtMost(usize, 0, 12));
    for (cores) |*core| core.* = rng.intRangeAtMost(u16, 0, 63);
    std.mem.sort(u16, cores, {}, std.sort.asc(u16));

    var unique: usize = 0;
    for (cores) |core| {
        if (unique == 0 or cores[unique - 1] != core) {
            cores[unique] = core;
            unique += 1;
        }
    }
    return .{ .cores = cores[0..unique] };
}

fn randomLogging(rng: std.Random, allocator: std.mem.Allocator) !Logging {
    return switch (rng.intRangeAtMost(u8, 0, 2)) {
        0 => .{ .pretty = switch (rng.intRangeAtMost(u8, 0, 2)) {
            0 => .light,
            1 => .dark,
            else => .flat,
        } },
        1 => .{ .json = {} },
        else => .{ .file = try randomString(rng, allocator, 4 + rng.intRangeAtMost(usize, 0, 12)) },
    };
}

fn randomConfig(rng: std.Random, allocator: std.mem.Allocator) !Config {
    return .{
        .bind = try randomString(rng, allocator, 1 + rng.intRangeAtMost(usize, 0, 12)),
        .port = rng.int(u16),
        .fronts = rng.int(u16),
        .front_cores = try randomMask(rng, allocator),
        .indexes = rng.int(u16),
        .index_cores = try randomMask(rng, allocator),
        .elephants = rng.int(u16),
        .host_index = rng.int(u16),
        .logging = try randomLogging(rng, allocator),
        .queue_depth = rng.int(u32),
        .init_timeout_sec = rng.int(u32),
        .shutdown_timeout_sec = rng.int(u32),
        .cross_task_slots = rng.int(u32),
        .accept_backlog = rng.int(u32),
        .sqpoll_threads = rng.int(u32),
    };
}

test "config: round robin with random values" {
    var fixture = Fixture.init();
    defer fixture.deinit();
    try fixture.start();

    var prng = std.Random.DefaultPrng.init(0x51667);
    const rng = prng.random();
    const allocator = fixture.values.allocator();

    var round: usize = 0;
    while (round < 32) : (round += 1) {
        const original = try randomConfig(rng, allocator);
        const text = fixture.p.stringify(original);
        try testing.expect(text.len > 0);

        const decoded = try fixture.p.parse(text);
        try testing.expectEqualDeep(original, decoded);
        try testing.expectEqualSlices(u16, original.front_cores.cores, decoded.front_cores.cores);
        try testing.expectEqualSlices(u16, original.index_cores.cores, decoded.index_cores.cores);
    }
}

test "config: mask encodes ranges compactly" {
    var fixture = Fixture.init();
    defer fixture.deinit();
    try fixture.start();

    var value: Config = .{};
    value.front_cores = .{ .cores = &.{ 9, 0, 1, 2, 4, 5, 6, 7, 8 } };
    const text = fixture.p.stringify(value);
    try testing.expect(std.mem.indexOf(u8, text, "front_cores = { 0 1 2 4..9 }") != null);

    const decoded = try fixture.p.parse(text);
    try testing.expectEqualSlices(u16, &.{ 0, 1, 2, 4, 5, 6, 7, 8, 9 }, decoded.front_cores.cores);
}

const config_text =
    \\# deployment example
    \\bind = "0.0.0.0"
    \\port = 7000
    \\fronts = 3
    \\front_cores = { 0 1 2 4..9 }
    \\indexes = 2
    \\index_cores = { 10 11 }
    \\elephants = 0
    \\host_index = 1
    \\logging = pretty { flat }
    \\queue_depth = 8192
    \\init_timeout_sec = 3
    \\shutdown_timeout_sec = 4
    \\cross_task_slots = 512
    \\accept_backlog = 128
    \\sqpoll_threads = 2
;

test "config: text config decodes to expected values" {
    var fixture = Fixture.init();
    defer fixture.deinit();
    try fixture.start();

    const config = try fixture.p.parse(config_text);
    try testing.expectEqualStrings("0.0.0.0", config.bind);
    try testing.expectEqual(@as(u16, 7000), config.port);
    try testing.expectEqual(@as(u16, 3), config.fronts);
    try testing.expectEqualSlices(u16, &.{ 0, 1, 2, 4, 5, 6, 7, 8, 9 }, config.front_cores.cores);
    try testing.expectEqual(@as(u16, 2), config.indexes);
    try testing.expectEqualSlices(u16, &.{ 10, 11 }, config.index_cores.cores);
    try testing.expectEqual(@as(u16, 0), config.elephants);
    try testing.expectEqual(@as(u16, 1), config.host_index);
    try testing.expectEqual(Logging{ .pretty = .flat }, config.logging);
    try testing.expectEqual(@as(u32, 8192), config.queue_depth);
    try testing.expectEqual(@as(u32, 3), config.init_timeout_sec);
    try testing.expectEqual(@as(u32, 4), config.shutdown_timeout_sec);
    try testing.expectEqual(@as(u32, 512), config.cross_task_slots);
    try testing.expectEqual(@as(u32, 128), config.accept_backlog);
    try testing.expectEqual(@as(u32, 2), config.sqpoll_threads);
}

test "config: logging variants and mask edge cases" {
    var fixture = Fixture.init();
    defer fixture.deinit();
    try fixture.start();

    const json = try fixture.p.parse("logging = json");
    try testing.expectEqual(Logging{ .json = {} }, json.logging);

    const file = try fixture.p.parse("logging = file { \"/var/log/siggy.log\" }");
    try testing.expectEqualStrings("/var/log/siggy.log", file.logging.file);

    const empty = try fixture.p.parse("front_cores = { }");
    try testing.expectEqual(@as(usize, 0), empty.front_cores.cores.len);
    try testing.expectEqualSlices(u16, &.{ 4, 5, 6, 7 }, empty.index_cores.cores);

    try testing.expectError(error.Custom, fixture.p.parse("front_cores = { 5..3 }"));
    try testing.expectError(error.Custom, fixture.p.parse("front_cores = { abc }"));
    try testing.expectError(error.Custom, fixture.p.parse("front_cores = { 70000 }"));
    try testing.expectError(error.MixedListSeparators, fixture.p.parse("front_cores = { 1, 2 3 }"));
}
