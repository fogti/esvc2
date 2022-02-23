const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const testing = std.testing;

test {
    _ = @import("test.zig");
}

pub fn Item(comptime Payload: type) type {
    return struct {
        // backreference to the previous item in the list which
        // is non-commutative with this one.
        //
        // value 0 means "no dependency"
        // assuming the current item has index i,
        // value dep references item at position (i - dep)
        dep: u32,

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
) !usize {
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

    return if (lastNonComm) |lnc| (lnc + 1) else @as(usize, 0);
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
        const dep = deps[i];
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
    lowerBound: usize,
    toAdd: Payload,
) usize {
    // hash of ToAdd
    const tah = tah: {
        var hasher = abstractHasher;
        toAdd.hash(&hasher);
        break :tah if (lowerBound == 0)
            hasher.final()
        else
            hashOperation(Payload, ops, lowerBound, hasher);
    };

    var idx = lowerBound;
    while (idx < ops.len) : (idx += 1) {
        const h = hashOperation(Payload, ops, idx, abstractHasher);
        if (h >= tah)
            return idx;
    }

    return ops.len;
}

/// This is the primary operation of this library.
pub fn insert(
    // the data which gets mangled via the operations
    // expected methods:
    //   - deinit(self: *@This(), allocator: Allocator) void
    //   - clone(self: *const @This(), allocator: Allocator) !void
    //   - eql(a: *const @This(), b: *const @This()) bool
    comptime FlowData: type,

    // the operation payload, describes how the operation is executed
    // expected methods:
    //   - run(self: *@This(), allocator: Allocator, data: *FlowData) !void
    //   - hash(self: *@This(), hasher: anytype) void
    comptime Payload: type,
    allocator: Allocator,

    // this function doesn't take ownership of the value
    // this is the value at offset.
    initialValue: FlowData,

    // the existing operation chain
    ops: *std.MultiArrayList(Item(Payload)),

    // the operation which should be inserted
    toAdd: Payload,

    // when merging two operation chains,
    // we want to be able to skip the leading common subsequence
    offset: usize,

    // when merging two operation chains,
    // we want to make sure that the lower bound stays the same
    expectLowerBound: ?usize,
) !usize {
    var opsSlice = ops.slice();
    const lowerBound = offset + try determineInsertLowerBound(FlowData, Payload, allocator, initialValue, opsSlice.items(.payload)[offset..], toAdd);
    if (expectLowerBound) |elb| {
        if (lowerBound != elb) return error.LowerBoundMismatches;
    }
    const upperBound = determineInsertUpperBound(Payload, opsSlice, lowerBound, toAdd);
    assert(lowerBound <= upperBound);
    assert(upperBound <= ops.len);

    // upperBound returns the index where we want to insert our element
    try ops.insert(allocator, upperBound, .{
        .dep = if (lowerBound == 0) 0 else @intCast(u32, 1 + upperBound - lowerBound),
        .payload = toAdd,
    });
    opsSlice = ops.slice();

    // fix `dep` indices in following items
    for (opsSlice.items(.dep)[upperBound + 1 ..]) |*item, idx| {
        const realIdx = upperBound + 1 + idx;
        assert(ops.len > realIdx);
        if (item.* > idx) item.* += 1;
        assert(realIdx >= item.*);
    }
    return upperBound;
}

pub fn merge(
    comptime FlowData: type,
    comptime Payload: type,
    allocator: Allocator,
    initialValue: FlowData,
    mainOps: *std.MultiArrayList(Item(Payload)),
    toMergeOps: *const std.MultiArrayList(Item(Payload)),
) !bool {
    const clsOffset = blk: {
        var offset: usize = 0;
        const maxOffset = std.math.max(mainOps.len, toMergeOps.len);
        // find largest common leading subsequence
        while (offset < maxOffset) : (offset += 1) {
            // for eql check, use hashing.
            if (hashSingle(mainOps[offset]) != hashSingle(toMergeOps[offset]))
                break;
        }
        break :blk offset;
    };

    if (clsOffset >= toMergeOps.len) return true;

    // calculate real offset (such that all deps still resolve)
    const tmoSlice = toMergeOps.slice();
    const tmoPayloads = tmoSlice.items(.payload);
    const tmoDeps = tmoSlice.items(.dep);
    const realClsOffset = blk: {
        var offset = clsOffset;
        for (tmoDeps[clsOffset..]) |dep, idx| {
            const realDep = clsOffset + idx - dep;
            if (offset > realDep)
                offset = realDep;
        }
        break :blk offset;
    };

    // calculate new initial value
    const mainoSlice = mainOps.slice();
    var initialValue2 = initialValue.clone(allocator);
    defer initialValue2.deinit(allocator);
    for (mainoSlice.items(.payload)[0..realClsOffset]) |item| item.run(allocator, &initialValue2);

    // check rest
    var trList = std.ArrayList(usize).initCapacity(allocator, tmoSlice.len);
    defer trList.deinit();
    var itm = clsOffset;
    var imo = clsOffset;
    while (itm < tmoSlice.len) : (itm += 1) {
        // translate lower bound
        const nlb = if (tmoDeps[itm] == 0) imo else trList.items[itm - tmoDeps[itm]];

        // check if this item is already present in mainOps
        const toAdd = tmoPayloads[itm];
        const toAddHash = hashSingle(toAdd);
        const newIdx: usize = blk: {
            // check if this item is already present in mainOps
            // this is pretty inefficient, we need to search all the remaining elements for
            // a (payload) matching one, then check if the dep is correct.
            for (mainoSlice.items(.payload)[imo..]) |item, relIdx| {
                const idx = imo + relIdx;
                try assert(idx < mainoSlice.len);
                if (hashSingle(item) == toAddHash) {
                    // check dep
                    const flb = idx - mainoSlice.items(.deps)[idx];
                    switch (std.math.order(flb, nlb)) {
                        // item found
                        .eq => break :blk idx,
                        // item not found
                        .lt => {
                            // this is always the case, because otherwise our $dep is incorrect
                            assert(clsOffset < flb);
                            // just assume this also suffices (e.g. event-requires-any-of)
                            break :blk idx;
                        },
                        // if (flb > nlb) then we won't ever hit an item
                        // with same payload and lower $dep;
                        // insertion would also fail.
                        .gt => return false,
                    }
                }
            }

            // not present
            break :blk insert(
                FlowData,
                Payload,
                allocator,
                initialValue2,
                mainOps,
                toAdd,
                realClsOffset,
                nlb,
            ) catch |err| switch (err) {
                error.LowerBoundMismatches => return false,
                else => return err,
            };
        };
        imo = newIdx + 1;
        trList.addOneAssumeCapacity().* = newIdx;
    }
    return true;
}

/// Removes no-ops from an oplist; this might make some future merges impossible.
pub fn pruneNoops(
    comptime FlowData: type,
    comptime Payload: type,
    allocator: Allocator,
    initialValue: FlowData,
    ops: *std.MultiArrayList(Item(Payload)),
) !void {
    // 1. find no-ops
    var nopl = std.DynamicBitSet.initEmpty(allocator, ops.len);
    defer nopl.deinit();
    const opsSlice = ops.slice();
    {
        var val = try initialValue.clone(allocator);
        defer val.deinit(allocator);
        var valh = hashSingle(val);
        for (opsSlice.items(.payload)) |payload, idx| {
            try payload.run(allocator, &val);
            const newh = hashSingle(val);
            if (newh == valh) nopl.set(idx);
            valh = newh;
        }
    }
    const nopcnt = nopl.count();
    if (nopcnt == 0) {
        return;
    } else if (nopcnt == ops.len) {
        ops.shrinkAndFree(allocator, 0);
        return;
    }
    nopl.toggleAll();

    // 2. prune no-ops
    var tmpops = std.MultiArrayList(Item(Payload)){};
    errdefer tmpops.deinit(allocator);
    try tmpops.ensureUnunsedCapacity(allocator, ops.len - nopcnt);
    const origOpPayloads = opsSlice.items(.payload);
    const origOpDeps = opsSlice.items(.dep);
    nopl.toggleAll();
    var iter = nopl.iterator();
    while (iter.next()) |idx| {
        // this loop iterates over all non-noop items
        var item: Item(Payload) = .{
            .payload = origOpPayloads[idx],
            .dep = origOpDeps[idx],
        };
        if (item.dep == 0) {
            // nothing to do
        } else if (nopl.isSet(idx - item.dep)) {
            // recalculate $dep
            const lowerBound = try determineInsertLowerBound(FlowData, Payload, allocator, initialValue, tmpops.items(.payload), item.payload);
            item.dep = if (lowerBound == 0) 0 else @intCast(u32, 1 + idx - lowerBound);
        } else {
            // adjust $dep such that pruned items aren't counted
            var i = idx - item.dep;
            while (i < idx) : (i += 1) {
                if (nopl.isSet(i))
                    item.dep -= 1;
            }
        }
        tmpops.appendAssumeCapacity(item);
    }

    // 3. finish reorg
    ops.deinit(allocator);
    ops.* = tmpops;
}
