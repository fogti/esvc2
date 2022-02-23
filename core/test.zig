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
    var xs = std.MultiArrayList(esvc.Item(Payload)){};
    defer xs.deinit(testing.allocator);

    const ir0 = try esvc.insert(
        FlowData,
        Payload,
        testing.allocator,
        .{ .inner = false },
        &xs,
        .{ .invert = true },
        0,
        0,
    );
    try testing.expectEqual(@as(usize, 0), ir0);
    const ir1 = try esvc.insert(
        FlowData,
        Payload,
        testing.allocator,
        .{ .inner = true },
        &xs,
        .{ .invert = true },
        0,
        0,
    );
    try testing.expectEqual(@as(usize, 0), ir1);
}
