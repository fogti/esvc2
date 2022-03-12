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
    var xs = esvc.Esvc(FlowData, Payload){ .allocator = testing.allocator };
    defer xs.deinit();

    const ir0 = try xs.insert(.{ .inner = false }, .{ .invert = true }, 0);
    try testing.expectEqual(@as(usize, 0), ir0);
    const ir1 = try xs.insert(.{ .inner = true }, .{ .invert = true }, 0);
    try testing.expectEqual(@as(usize, 1), ir1);
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
            switch (self.*) {
                .add => |v| {
                    std.hash.autoHash(hasher, @as(u8, 0));
                    std.hash.autoHash(hasher, v);
                },
                .mul => |v| {
                    std.hash.autoHash(hasher, @as(u8, 1));
                    std.hash.autoHash(hasher, v);
                },
            }
        }
    };
    break :blk esvc.Esvc(FlowData, Payload);
};

test "i32" {
    var xs = I32Esvc{ .allocator = testing.allocator };
    defer xs.deinit();
    const initval: I32Esvc.FlowData = .{ .inner = 0 };

    try testing.expectEqual(@as(usize, 0), try xs.insert(initval, .{ .add = 0 }, 0));
    try testing.expectEqual(@as(usize, 0), try xs.insert(initval, .{ .add = 1 }, 0));
    try testing.expectEqual(@as(usize, 1), try xs.insert(initval, .{ .mul = 2 }, 0));
    try testing.expectEqual(@as(usize, 2), try xs.insert(initval, .{ .add = 5 }, 0));
    try testing.expectEqual(@as(usize, 3), try xs.insert(initval, .{ .mul = 4 }, 0));
    try testing.expectEqual(@as(usize, 4), try xs.insert(initval, .{ .add = -1 }, 0));
    try testing.expectEqual(@as(usize, 5), try xs.insert(initval, .{ .add = -1 }, 0));
    try testing.expectEqual(@as(usize, 6), try xs.insert(initval, .{ .add = -2 }, 0));
    std.debug.print("[1] Tdeps: {any}\nTpayloads: {any}\n", .{ xs.ops.items(.dep), xs.ops.items(.payload) });

    var xs2 = I32Esvc{ .allocator = xs.allocator };
    {
        errdefer xs2.deinit();

        // populate xs2 with .{ +1, *2, +5, *4 }
        {
            var i: usize = 0;
            while (i < 4) : (i += 1) {
                try xs2.ops.append(testing.allocator, xs.ops.get(i));
            }
        }

        try testing.expectEqual(@as(usize, 4), try xs2.insert(initval, .{ .add = 0 }, 0));
        try testing.expectEqual(@as(usize, 4), try xs2.insert(initval, .{ .add = 1 }, 0));
        //try testing.expectEqual(@as(usize, 5), try xs2.insert(initval, .{ .mul = 2 }, 0));
        try testing.expectEqual(@as(usize, 4), try xs2.insert(initval, .{ .add = 5 }, 0));
        //try testing.expectEqual(@as(usize, 6), try xs2.insert(initval, .{ .mul = 4 }, 0));
        try testing.expectEqual(@as(usize, 6), try xs2.insert(initval, .{ .add = -1 }, 0));
        try testing.expectEqual(@as(usize, 7), try xs2.insert(initval, .{ .add = -1 }, 0));
        try testing.expectEqual(@as(usize, 8), try xs2.insert(initval, .{ .add = -2 }, 0));
    }

    // try to merge them.
    std.debug.print("[2] Tdeps: {any}\nTpayloads: {any}\n", .{ xs2.ops.items(.dep), xs2.ops.items(.payload) });
    try testing.expectEqual(true, try xs.merge(initval, &xs2.ops));
    std.debug.print("[R] Tdeps: {any}\nTpayloads: {any}\n", .{ xs.ops.items(.dep), xs.ops.items(.payload) });

    // try to prune noops
    try xs.pruneNoops(initval);
    std.debug.print("[P] Tdeps: {any}\nTpayloads: {any}\n", .{ xs.ops.items(.dep), xs.ops.items(.payload) });
}
