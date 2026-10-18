//! Worked example from the schema spec: CPU thread masks.

const std = @import("std");
const siggy = @import("../root.zig");

pub const Range = struct {
    start: u32,
    end: u32,
};

/// A mask item is either a single thread index or an inclusive range.
pub const MaskItem = union(enum) {
    /// Literal `0`, `1`, ... deserializes here because the variant is non-void
    /// and named `literal`.
    literal: u32,
    /// Tagged block `range { start = 10 end = 12 }`.
    range: Range,
};

pub const CpuConfig = struct {
    index_threads_mask: []const MaskItem,
    pin_threads_mask: []const MaskItem = &.{},
};

pub const Config = siggy.parser(CpuConfig);

fn silentPrinter(allocator: std.mem.Allocator, diag: *siggy.Diagnostics) anyerror!void {
    _ = allocator;
    _ = diag;
}
pub const Parser = Config;

test "mask: example config parses" {
    var value_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer value_arena.deinit();

    var p: Config = undefined;
    try p.init(std.testing.allocator, value_arena.allocator(), silentPrinter);

    const config = try p.parse(
        \\# Threads used for the index build.
        \\index_threads_mask = { 0 1 range { start = 10 end = 12 } }
        \\pin_threads_mask = { 2, 3, 20, 21, }
    );

    try std.testing.expectEqual(@as(usize, 3), config.index_threads_mask.len);
    try std.testing.expectEqual(MaskItem{ .literal = 0 }, config.index_threads_mask[0]);
    try std.testing.expectEqual(MaskItem{ .literal = 1 }, config.index_threads_mask[1]);
    try std.testing.expectEqual(
        MaskItem{ .range = .{ .start = 10, .end = 12 } },
        config.index_threads_mask[2],
    );

    try std.testing.expectEqual(@as(usize, 4), config.pin_threads_mask.len);
    try std.testing.expectEqual(MaskItem{ .literal = 21 }, config.pin_threads_mask[3]);
}

test "mask: round trip through stringify" {
    var value_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer value_arena.deinit();

    var p: Config = undefined;
    try p.init(std.testing.allocator, value_arena.allocator(), silentPrinter);

    const original = CpuConfig{
        .index_threads_mask = &[_]MaskItem{
            .{ .literal = 0 },
            .{ .literal = 1 },
            .{ .range = .{ .start = 10, .end = 12 } },
        },
        .pin_threads_mask = &[_]MaskItem{.{ .literal = 2 }},
    };

    const text = p.stringify(original);
    try std.testing.expect(text.len > 0);
    const reparsed = try p.parse(text);
    try std.testing.expectEqual(original.index_threads_mask.len, reparsed.index_threads_mask.len);
    try std.testing.expectEqual(original.index_threads_mask[2].range.end, reparsed.index_threads_mask[2].range.end);
    try std.testing.expectEqual(original.pin_threads_mask.len, reparsed.pin_threads_mask.len);
}
