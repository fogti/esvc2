const std = @import("std");
const esvc_core = @import("esvc-core");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const Address = @import("addr.zig").Address;
const CommandKind = @import("cmd.zig").CommandKind;

test {
    _ = Address;
    _ = CommandKind;
}

const Command = struct {
    addr: Address,
    kind: CommandKind,
    // switch_autoindent: bool,

    pub fn deinit(self: *Command, allocator: Allocator) void {
        self.addr.deinit(allocator);
        self.kind.deinit(allocator);
    }

    pub fn format(
        self: *const Command,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        writer.print("{} {}", .{ self.addr, self.kind });
    }
};
