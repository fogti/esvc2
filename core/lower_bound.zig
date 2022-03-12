const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

pub const RelativeDep = struct {
    // value 0 means "no dependency"
    // otherwise assuming the associated item has index i
    // value $dep=.value references item at position (i - $dep=.value)
    value: u32,
};

// conversion functions
pub fn abs(lb: RelativeDep, pos: usize) ?usize {
    return if (lb.value == 0) null else (pos - @intCast(usize, lb.value));
}
pub fn rel(lba: ?usize, pos: usize) RelativeDep {
    return .{ .value = @intCast(u32, if (lba) |lba2| (pos - lba2) else 0) };
}

test "lower bound conv" {
    try testing.expectEqual(@as(?usize, null), abs(.{ .value = 0 }, 100));

    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        var j: usize = @intCast(usize, i);
        while (j < 100) : (j += 1) {
            const x = RelativeDep{ .value = i };
            try testing.expectEqual(x, rel(abs(x, j), j));
        }
    }
}

pub const InsertLowerBound = struct {
    value: usize,

    const Self = @This();

    /// converts an ILB value to an absolute index
    pub fn toAbsolute(self: Self, offset: usize) ?usize {
        const v = self.value;
        return if (v == 0) null else (offset + v - 1);
    }

    /// converts an ILB value to a relative `dep` value
    pub fn toRelative(self: Self, offset: usize, position: usize) RelativeDep {
        assert(offset <= position);
        return rel(self.toAbsolute(offset), position);
    }
};

test "InsertLowerBound toAbsolute" {
    try testing.expectEqual(@as(?usize, null), (InsertLowerBound{ .value = 0 }).toAbsolute(0));
    try testing.expectEqual(@as(?usize, 0), (InsertLowerBound{ .value = 1 }).toAbsolute(0));
    try testing.expectEqual(@as(?usize, 9), (InsertLowerBound{ .value = 5 }).toAbsolute(5));
    try testing.expectEqual(@as(?usize, null), (InsertLowerBound{ .value = 0 }).toAbsolute(5));
}

test "InsertLowerBound toRelative" {
    const S = struct {
        pub fn roundTrip(rd: u32, ilb: usize, offset: usize, pos: usize) !void {
            try testing.expectEqual(RelativeDep{ .value = rd }, (InsertLowerBound{ .value = ilb }).toRelative(offset, pos));
        }
    };
    try S.roundTrip(0, 0, 0, 0);
    try S.roundTrip(0, 0, 0, 1);
    try S.roundTrip(1, 1, 0, 1);
    try S.roundTrip(2, 1, 0, 2);
    try S.roundTrip(1, 2, 0, 2);
    try S.roundTrip(1, 2, 5, 7);
    try S.roundTrip(14, 5, 5, 23);
}
