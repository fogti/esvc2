const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

fn parseLnum(s: *[]const u8) !usize {
    var ret: usize = 0;
    const endOfNum = blk: {
        for (s.*) |i, idx| {
            switch (i) {
                '0', '1', '2', '3', '4', '5', '6', '7', '8', '9' => ret = ret * 10 + (i - '0'),
                else => break :blk idx,
            }
        }
        break :blk s.*.len;
    };
    if (endOfNum == 0)
        return error.NotANumber;
    s.* = s.*[endOfNum..];
    return ret;
}

pub const Address = union(enum) {
    rgx: []const u8,
    rng: struct {
        begin: usize,
        end: usize,
    },
    rngf: usize,
    last,

    pub fn deinit(self: *Address, allocator: Allocator) void {
        switch (self.*) {
            Address.rgx => |rgx| allocator.free(rgx),
            else => {},
        }
        self.* = undefined;
    }

    pub fn format(
        self: *const Address,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        return switch (self) {
            .rgx => |rgx| writer.print("/{s}/", .{rgx}),
            .rng => |rng| writer.print("{d},{d}", .{ rng.begin, rng.end }),
            .rngf => |rngf| writer.print("{d},", .{rngf}),
            .last => writer.print("$"),
        };
    }

    pub fn parse(allocator: Allocator, s: *[]const u8) !Address {
        const sdr = s.*;
        if (sdr.len == 0) return error.InvalidAddress;
        switch (sdr[0]) {
            '$' => {
                s.* = sdr[1..];
                return Address.last;
            },
            '/' => {
                var escaped = false;
                var rgxs = std.ArrayList(u8).init(allocator);
                errdefer rgxs.deinit();
                for (sdr[1..]) |i, idx| {
                    if (i == '\'') {
                        escaped = !escaped;
                        if (escaped) continue;
                        (try rgxs.addOne()).* = '\'';
                    } else if (escaped) {
                        const reali: u8 = switch (i) {
                            'n' => '\n',
                            't' => 't',
                            '/' => '/',
                            else => return error.InvalidAddress,
                        };
                        (try rgxs.addOne()).* = reali;
                        escaped = false;
                    } else if (i == '/') {
                        s.* = sdr[idx + 2 ..];
                        break;
                    } else {
                        (try rgxs.addOne()).* = i;
                    }
                }
                if (escaped)
                    return error.EscapedEndOfLine;
                return Address{ .rgx = rgxs.toOwnedSlice() };
            },
            '0', '1', '2', '3', '4', '5', '6', '7', '8', '9' => {
                // parse line number
                const a = parseLnum(s) catch unreachable;
                if (s.*.len != 0 and s.*[0] == ',') {
                    s.* = s.*[1..];
                    if (parseLnum(s)) |b| {
                        if (a < b) {
                            return Address{ .rng = .{ .begin = a, .end = b } };
                        } else {
                            return error.InvalidAddress;
                        }
                    } else |_| {
                        return Address{ .rngf = a };
                    }
                } else {
                    return Address{ .rng = .{ .begin = a, .end = a + 1 } };
                }
            },
            else => return error.InvalidAddress,
        }
    }

    //const ResolvedLineSegment = struct {
    //    selected: bool,
    //    dat: [][]const u8,
    //
    //    pub fn deinit()
    //};
    //
    //pub fn resolve(self: *const Self, allocator: Allocator, dat: []const []const u8) !std.DynamicBitSet {
    //  var ret = std.DynamicBitSet.initEmpty(allocator, dat.len + 1);
    //  errdefer ret.deinit();
    //
    //  switch (self) {
    //    .rng => |rng| {
    //      if (rng.begin >= dat.len || rng.begin >= rng.end) {
    //        // do nothing
    //      } else if (rng.end >= dat.len) {
    //        var offset = rng.begin;
    //        while (offset <= dat.len) : (offset += 1) {
    //          ret.set(offset);
    //        }
    //      }
    //    },
    //    .last => ret.set(dat.len),
    //  }
    //  return ret;
    //}
};

fn test_xsimple(inp: []const u8, addr: Address, rest: []const u8) !void {
    var s: []const u8 = inp;
    var r = try Address.parse(testing.allocator, &s);
    defer r.deinit(testing.allocator);
    switch (addr) {
        .rgx => |lhsrgx| {
            switch (r) {
                .rgx => |rhsrgx| try testing.expectEqualSlices(u8, lhsrgx, rhsrgx),
                else => try testing.expectEqual(addr, r),
            }
        },
        else => try testing.expectEqual(addr, r),
    }
    try testing.expectEqualSlices(u8, rest, s);
}
test "address parsing" {
    try test_xsimple("$", Address.last, "");
    try test_xsimple("0", .{ .rng = .{ .begin = 0, .end = 1 } }, "");
    try test_xsimple("0,", .{ .rngf = 0 }, "");
    try test_xsimple("1", .{ .rng = .{ .begin = 1, .end = 2 } }, "");
    try test_xsimple("$1", Address.last, "1");
    const rgx0 = "/hewwo?/";
    try test_xsimple(rgx0, .{ .rgx = rgx0[1..7] }, "");
    const rgx1 = "/hewwo?/1";
    try test_xsimple(rgx1, .{ .rgx = rgx1[1..7] }, "1");
}
