const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const testing = std.testing;
const esvc = @import("main.zig");

test "simple" {
    const FlowData = esvc.PlainOldFlowData(bool);
    const Payload = struct {
        invert: bool,

        const Payload = @This();

        pub fn run(self: *const Payload, allocator: Allocator, dat: *FlowData) !void {
            _ = allocator;
            if (self.invert)
                dat.*.inner = !dat.*.inner;
        }

        pub fn hash(self: *const Payload, hasher: anytype) void {
            std.hash.autoHash(hasher, self.*);
        }
    };
    var xs = esvc.Esvc(FlowData, Payload) { .allocator = testing.allocator };
    defer xs.deinit();

    const ir0 = try xs.insert(.{ .inner = false }, .{ .invert = true }, 0, 0);
    try testing.expectEqual(@as(usize, 0), ir0);
    const ir1 = try xs.insert(.{ .inner = true }, .{ .invert = true }, 0, 0);
    try testing.expectEqual(@as(usize, 0), ir1);
}

const I32Esvc = blk: {
    const FlowData = esvc.PlainOldFlowData(i32);
    const Payload = union(enum) {
        add: i32,
        mul: i32,
        const Payload = @This();
        pub fn deinit(self: *Payload, allocator: Allocator) void {
            _ = allocator;
            self.* = undefined;
        }
        pub fn clone(self: *const Payload, allocator: Allocator) !Payload {
            _ = allocator;
            return self.*;
        }
        pub fn run(self: *const Payload, allocator: Allocator, dat: *FlowData) !void {
            _ = allocator;
            switch (self.*) {
                .add => |v| dat.inner += v,
                .mul => |v| dat.inner *= v,
            }
        }
        pub fn hash(self: *const Payload, hasher: anytype) void {
            std.hash.autoHash(hasher, self.*);
        }
    };
    break :blk esvc.Esvc(FlowData, Payload);
};

test "i32" {
    var xs = I32Esvc { .allocator = testing.allocator };
    defer xs.deinit();
    const initval: I32Esvc.FlowData = .{ .inner = 0 };

    try testing.expectEqual(@as(usize, 0), try xs.insert(initval, .{ .add = 0 }, 0, 0));
    try testing.expectEqual(@as(usize, 0), try xs.insert(initval, .{ .add = 1 }, 0, 0));
    try testing.expectEqual(@as(usize, 1), try xs.insert(initval, .{ .mul = 2 }, 0, 1));
    try testing.expectEqual(@as(usize, 2), try xs.insert(initval, .{ .add = 5 }, 0, 2));
    try testing.expectEqual(@as(usize, 3), try xs.insert(initval, .{ .mul = 4 }, 0, 3));
    try testing.expectEqual(@as(usize, 4), try xs.insert(initval, .{ .add = -1 }, 0, 4));
    try testing.expectEqual(@as(usize, 5), try xs.insert(initval, .{ .add = -1 }, 0, 4));
    try testing.expectEqual(@as(usize, 4), try xs.insert(initval, .{ .add = -2 }, 0, 4));
}
