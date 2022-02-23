const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn skipSpaces(s: *[]const u8) void {
    var offset = 0;
    const sdr = s.*;
    while (offset < sdr.len and sdr[offset] == ' ') : (offset += 1) {}
    s.* = s.*[offset..];
}

pub const CommandKind = union(enum) {
    append: [][]const u8,
    change: [][]const u8,
    delete,
    insert: [][]const u8,
    subst: struct {
        pat: []const u8,
        repl: []const u8,
    },

    const Self = @This();

    pub fn deinit(self: *Self, allocator: Allocator) void {
        switch (self) {
            .append,
            .change,
            .insert,
            => |ll| {
                for (ll) |l| allocator.free(l);
                allocator.free(ll);
            },
            .delete => {},
            .subst => |subst| {
                allocator.free(subst.pat);
                allocator.free(subst.repl);
            },
        }
        self.* = undefined;
    }

    pub fn format(
        self: *const Self,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        const stc: u8 = switch (self) {
            .append => 'a',
            .change => 'c',
            .insert => 'i',
            .delete => 'd',
            .subst => 's',
        };
        try writer.print("{c}", .{stc});
        switch (self) {
            .append,
            .change,
            .insert,
            => |xs| {
                try writer.print("\n", .{});
                for (xs) |i| try writer.print("{s}\n", .{i});
            },
            .delete => {},
            .subst => |subst| try writer.print("\n{s}\n{s}", .{ subst.pat, subst.repl }),
        }
    }

    pub fn parseKind(s: *[]const u8) !Self {
        skipSpaces(s);
        if (s.*.len == 0) return error.NoCommand;
        const olds = s.*;
        errdefer s.* = olds;
        s.* = s.*[1..];
        return switch (olds[0]) {
            'a' => Self.append,
            'c' => Self.change,
            'i' => Self.insert,
            'd' => Self.delete,
            's' => Self.subst,
            else => error.UnknownCommand,
        };
    }
};
