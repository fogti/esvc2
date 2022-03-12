const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const testing = std.testing;
const lb = @import("lower_bound.zig");

test {
    _ = @import("test.zig");
}

pub fn Item(comptime Payload: type) type {
    return struct {
        // backreference to the previous item in the list which
        // is non-commutative with this one.
        dep: lb.RelativeDep = .{ .value = 0 },

        payload: Payload,
    };
}

pub fn PlainOldFlowData(comptime Inner: type) type {
    return struct {
        inner: Inner,
        const Self = @This();
        pub fn deinit(self: *Self, allocator: Allocator) void {
            _ = self;
            _ = allocator;
        }
        pub fn clone(self: *const Self, allocator: Allocator) !Self {
            _ = allocator;
            return self.*;
        }
        pub fn eql(a: *const Self, b: *const Self) bool {
            return a.*.inner == b.*.inner;
        }
    };
}

fn determineInsertLowerBound(
    comptime FlowData: type,
    comptime Payload: type,
    allocator: Allocator,
    initialValue: FlowData,
    payloads: []const Payload,
    toAdd: Payload,
) !lb.InsertLowerBound {
    // for simplicity and lower memory usage,
    // we iterate over the ops list in normal order, instead of in reverse.
    // also, we don't handle noop payloads different than others,
    // which reduces the amount of edge cases massively.

    var lastNonComm: ?usize = null;

    var flowData: FlowData = try initialValue.clone(allocator);
    defer flowData.deinit(allocator);

    // this should always hold (flowData | toAdd)
    var flowDataWithTa: FlowData = try initialValue.clone(allocator);
    defer flowDataWithTa.deinit(allocator);

    try toAdd.run(allocator, &flowDataWithTa);

    for (payloads) |item, idx| {
        // 1. prev-ops | item | toAdd
        try item.run(allocator, &flowData);
        var flowDataOne: FlowData = try flowData.clone(allocator);
        errdefer flowDataOne.deinit(allocator);
        try toAdd.run(allocator, &flowDataOne);
        // flowDataOne is the next flowDataWithTa

        // 2. prev-ops | toAdd | item
        try item.run(allocator, &flowDataWithTa);

        // compare
        if (!FlowData.eql(&flowDataOne, &flowDataWithTa)) {
            lastNonComm = idx;
        }

        // prepare next round
        flowDataWithTa.deinit(allocator);
        flowDataWithTa = flowDataOne;
    }

    return lb.InsertLowerBound{
        .value = if (lastNonComm) |lnc| (lnc + 1) else @as(usize, 0),
    };
}

fn hashOperation(
    comptime Payload: type,
    ops: std.MultiArrayList(Item(Payload)).Slice,
    initialop: usize,
    hasher: anytype,
) u64 {
    var i = initialop;
    var hasher_ = hasher;
    const payloads = ops.items(.payload);
    const deps = ops.items(.dep);
    while (true) {
        payloads[i].hash(&hasher_);
        const dep = deps[i].value;
        if (dep == 0) break;
        i -= dep;
    }
    return hasher_.final();
}

const abstractHasher = std.hash.Wyhash.init(0);

fn hashSingle(op: anytype) u64 {
    var hasher = abstractHasher;
    op.hash(&hasher);
    return hasher.final();
}

fn determineInsertUpperBound(
    comptime Payload: type,
    ops: std.MultiArrayList(Item(Payload)).Slice,
    lowerBound: lb.InsertLowerBound,
    toAdd: Payload,
    offset: usize,
) usize {
    const lba = lowerBound.toAbsolute(offset);

    // hash of ToAdd
    const tah = tah: {
        var hasher = abstractHasher;
        toAdd.hash(&hasher);
        break :tah if (lba) |lba2|
            hashOperation(Payload, ops, lba2, hasher)
        else
            hasher.final();
    };

    var idx = if (lba) |lba2| (lba2 + 1) else offset;
    while (idx < ops.len) : (idx += 1) {
        const h = hashOperation(Payload, ops, idx, abstractHasher);
        if (h > tah)
            return idx;
    }

    return ops.len;
}

/// this constructs the primary helper data structure, to avoid
/// passing around `FlowData` and `Payload`.
pub fn Esvc(
    // the data which gets mangled via the operations
    // expected methods:
    //   - deinit(self: *@This(), allocator: Allocator) void
    //   - clone(self: *const @This(), allocator: Allocator) !@This()
    //   - eql(a: *const @This(), b: *const @This()) bool
    comptime FlowData_: type,

    // the operation payload, describes how the operation is executed
    // expected methods:
    //   - deinit(self: *@This(), allocator: Allocator) void
    //   - clone(self: *const @This(), allocator: Allocator) !@This()
    //   - run(self: *@This(), allocator: Allocator, data: *FlowData) !void
    //   - hash(self: *@This(), hasher: anytype) void
    comptime Payload_: type,
) type {
    return struct {
        allocator: Allocator,
        ops: Ops = .{},

        const Self = @This();
        pub const FlowData = FlowData_;
        pub const Payload = Payload_;
        pub const Ops = std.MultiArrayList(Item(Payload));

        pub fn deinit(self: *Self) void {
            self.ops.deinit(self.allocator);
        }

        fn insertWithLowerBound(
            self: *Self,

            // the operation which should be inserted
            toAdd: Payload,
            lowerBound: lb.InsertLowerBound,
            offset: usize,
        ) !usize {
            var opsSlice = self.ops.slice();
            const upperBound = determineInsertUpperBound(
                Payload,
                opsSlice,
                lowerBound,
                toAdd,
                offset,
            );
            assert((lowerBound.toAbsolute(offset) orelse offset) <= upperBound);
            assert(upperBound <= self.ops.len);

            // upperBound returns the index where we want to insert our element
            try self.ops.insert(self.allocator, upperBound, .{
                .dep = lowerBound.toRelative(offset, upperBound),
                .payload = toAdd,
            });
            opsSlice = self.ops.slice();

            // fix `dep` indices in following items
            for (opsSlice.items(.dep)[upperBound + 1 ..]) |*item, idx| {
                const realIdx = upperBound + 1 + idx;
                assert(opsSlice.len > realIdx);
                if (item.*.value > idx) item.*.value += 1;
                assert(realIdx >= item.*.value);
            }
            return upperBound;
        }

        pub fn insert(
            self: *Self,

            // this function doesn't take ownership of the value
            // the value is assumed to be at offset.
            initialValue: FlowData,

            // the operation which should be inserted
            toAdd: Payload,

            // when merging two operation chains,
            // we want to be able to skip the leading common subsequence
            offset: usize,
        ) !usize {
            var opsSlice = self.ops.slice();
            const lowerBound = try determineInsertLowerBound(
                FlowData,
                Payload,
                self.allocator,
                initialValue,
                opsSlice.items(.payload)[offset..],
                toAdd,
            );
            return self.insertWithLowerBound(toAdd, lowerBound, offset);
        }

        pub fn merge(
            self: *Self,
            initialValue: FlowData,
            // this function does take ownership of toMergeOps
            toMergeOps: *Ops,
        ) !bool {
            defer {
                for (toMergeOps.items(.payload)) |*pl| pl.deinit(self.allocator);
                toMergeOps.deinit(self.allocator);
                toMergeOps.* = .{};
            }

            const tmoSlice = toMergeOps.slice();
            var mainoSlice = self.ops.slice();
            const clsOffset = blk: {
                var offset: usize = 0;
                const maxOffset = std.math.max(self.ops.len, toMergeOps.len);
                const tmoPayloads = tmoSlice.items(.payload);
                const mainPayloads = mainoSlice.items(.payload);
                const tmoDeps = tmoSlice.items(.dep);
                const mainDeps = mainoSlice.items(.dep);
                // find largest common leading subsequence
                while (offset < maxOffset) : (offset += 1) {
                    // for eql check, use hashing.
                    if (hashSingle(mainPayloads[offset]) != hashSingle(tmoPayloads[offset]))
                        break;
                    // if this fails, the data is corrupted
                    if (tmoDeps[offset].value != mainDeps[offset].value)
                        unreachable;
                }
                break :blk offset;
            };

            if (clsOffset >= toMergeOps.len) return true;

            // calculate real offset (such that all deps still resolve)
            const tmoPayloads = tmoSlice.items(.payload);
            const tmoDeps = tmoSlice.items(.dep);
            const realClsOffset = blk: {
                var offset = clsOffset;
                for (tmoDeps[clsOffset..]) |dep, idx| {
                    const rd = lb.abs(dep, clsOffset + idx);
                    if (rd) |realDep| {
                        if (offset > realDep)
                            offset = realDep;
                    }
                }
                break :blk offset;
            };

            // calculate new initial value
            var initialValue2 = try initialValue.clone(self.allocator);
            defer initialValue2.deinit(self.allocator);
            for (mainoSlice.items(.payload)[0..realClsOffset]) |item|
                try item.run(self.allocator, &initialValue2);

            // check rest
            var trList = try std.ArrayList(usize).initCapacity(self.allocator, tmoSlice.len);
            defer trList.deinit();
            var itm = clsOffset;
            var imo = clsOffset;
            {
                var i: usize = 0;
                while (i < clsOffset) : (i += 1) {
                    trList.addOneAssumeCapacity().* = i;
                }
            }
            while (itm < tmoSlice.len) : (itm += 1) {
                // translate lower bound
                if (trList.items.len != itm) {
                    std.debug.print("Esvc.merge: trList length = {d}, imo = {d}\n", .{ trList.items.len, imo });
                    @panic("trList not filled correctly");
                }
                //std.debug.print("Esvc.merge: itm = {d}; imo = {d}\n", .{ itm, imo });
                const nlb = if (lb.abs(tmoDeps[itm], itm)) |olb| trList.items[olb] else imo;

                // check if this item is already present in self.ops
                const toAdd = tmoPayloads[itm];
                const toAddHash = hashSingle(toAdd);
                //std.debug.print("\tnlb = {d}; payload = {any}; plh = {x}\n", .{
                //    nlb,
                //    toAdd,
                //    toAddHash,
                //});
                //std.debug.print("[M] Tdeps: {any}\n[M] Tpayloads: {any}\n", .{
                //    mainoSlice.items(.dep),
                //    mainoSlice.items(.payload),
                //});
                const newIdx: usize = blk: {
                    // check if this item is already present in self.ops
                    // this is pretty inefficient, we need to search all the remaining elements for
                    // a (payload) matching one, then check if the dep is correct.
                    for (mainoSlice.items(.payload)[imo..]) |item, relIdx| {
                        const idx = imo + relIdx;
                        assert(idx < mainoSlice.len);
                        if (hashSingle(item) == toAddHash) {
                            // check dep
                            const flb = lb.abs(mainoSlice.items(.dep)[idx], idx) orelse imo;
                            // if exact match => item found
                            if (flb != nlb) {
                                // not an exact match, but maybe the old lastNonComm got
                                // superseded by an earlier dependency (event-requires-any-of)
                                const llb = std.math.min(flb, nlb);
                                assert(realClsOffset <= llb);
                                const xlb = try determineInsertLowerBound(
                                    FlowData,
                                    Payload,
                                    self.allocator,
                                    initialValue2,
                                    mainoSlice.items(.payload)[realClsOffset..idx],
                                    // this also catches some hash collisions
                                    toAdd,
                                );
                                if (llb != (xlb.toAbsolute(realClsOffset) orelse imo)) {
                                    // $dep is incorrect
                                    std.debug.print("Esvc.merge: realClsOffset = {d}; clsOffset = {d}; idx = {d}; flb = {d}; nlb = {d}; xlb = {d}\n", .{
                                        realClsOffset,
                                        clsOffset,
                                        idx,
                                        flb,
                                        nlb,
                                        xlb,
                                    });
                                    return false;
                                }
                                // update $dep
                                mainoSlice.items(.dep)[idx] = xlb.toRelative(realClsOffset, idx);
                            }
                            break :blk idx;
                        }
                    }

                    // not present
                    const xdtlb = try determineInsertLowerBound(
                        FlowData,
                        Payload,
                        self.allocator,
                        initialValue2,
                        mainoSlice.items(.payload)[realClsOffset..],
                        toAdd,
                    );
                    {
                        const xlb = xdtlb.toAbsolute(realClsOffset) orelse imo;
                        if (xlb != nlb) {
                            std.debug.print("esvc.Esvc.merge: LowerBoundMismatches @ tmo item {d}: {any}; trList = {any}\n", .{
                                itm,
                                toAdd,
                                trList.items,
                            });
                            return false;
                        }
                    }
                    const tmp = try self.insertWithLowerBound(
                        // we clone the value here because it's easier than trying
                        // to keep track of which payloads were reused and which weren't.
                        try toAdd.clone(self.allocator),
                        xdtlb,
                        realClsOffset,
                    );
                    mainoSlice = self.ops.slice();
                    break :blk tmp;
                };
                imo = newIdx + 1;
                trList.addOneAssumeCapacity().* = newIdx;
                //std.debug.print("\n", .{});
            }
            return true;
        }

        /// Removes no-ops from an oplist; this might make some future merges impossible.
        pub fn pruneNoops(
            self: *Self,
            initialValue: FlowData,
        ) !void {
            const ops = &self.ops;
            // 1. find no-ops
            var nopl = try std.DynamicBitSet.initEmpty(self.allocator, ops.len);
            defer nopl.deinit();
            const opsSlice = ops.slice();
            {
                var val = try initialValue.clone(self.allocator);
                defer val.deinit(self.allocator);
                for (opsSlice.items(.payload)) |payload, idx| {
                    var oldval = try val.clone(self.allocator);
                    defer oldval.deinit(self.allocator);
                    try payload.run(self.allocator, &val);
                    if (FlowData.eql(&oldval, &val)) nopl.set(idx);
                }
            }
            const nopcnt = nopl.count();
            if (nopcnt == 0) {
                return;
            } else if (nopcnt == ops.len) {
                ops.shrinkAndFree(self.allocator, 0);
                return;
            }
            nopl.toggleAll();

            // 2. prune no-ops
            var tmpops = std.MultiArrayList(Item(Payload)){};
            errdefer tmpops.deinit(self.allocator);
            try tmpops.ensureUnusedCapacity(self.allocator, ops.len - nopcnt);
            const origOpPayloads = opsSlice.items(.payload);
            const origOpDeps = opsSlice.items(.dep);
            var iter = nopl.iterator(.{});
            while (iter.next()) |idx| {
                // this loop iterates over all non-noop items
                var item: Item(Payload) = .{
                    .payload = origOpPayloads[idx],
                    .dep = origOpDeps[idx],
                };
                if (lb.abs(item.dep, idx)) |deppos| {
                    if (!nopl.isSet(deppos)) {
                        // recalculate $dep
                        const lowerBound = try determineInsertLowerBound(
                            FlowData,
                            Payload,
                            self.allocator,
                            initialValue,
                            tmpops.items(.payload),
                            item.payload,
                        );
                        item.dep = lowerBound.toRelative(0, idx);
                    } else {
                        // adjust $dep such that pruned items aren't counted
                        var i = deppos;
                        while (i < idx) : (i += 1) {
                            if (!nopl.isSet(i))
                                item.dep.value -= 1;
                        }
                    }
                }
                tmpops.appendAssumeCapacity(item);
            }

            // 3. finish reorg
            for (origOpPayloads) |*pl, idx| if (!nopl.isSet(idx)) pl.deinit(self.allocator);
            ops.deinit(self.allocator);
            ops.* = tmpops;
        }
    };
}
