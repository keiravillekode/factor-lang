// float.zig - Boxed float helpers for the Factor VM.

const std = @import("std");
const layouts = @import("layouts.zig");
const vm_mod = @import("vm.zig");

const Cell = layouts.Cell;
const FactorVM = vm_mod.FactorVM;

// Allocate a boxed float via allotObject (handles nursery/tenured routing).
pub fn allocBoxedFloat(vm: *FactorVM, value: f64) !*layouts.BoxedFloat {
    const size = layouts.alignCell(@sizeOf(layouts.BoxedFloat), layouts.data_alignment);
    const tagged = vm.allotObject(.float, size) orelse return error.OutOfMemory;
    const boxed: *layouts.BoxedFloat = @ptrFromInt(layouts.UNTAG(tagged));
    boxed.n = value;
    return boxed;
}

// Untag a boxed float value.
pub fn untagFloat(cell: Cell) f64 {
    std.debug.assert(layouts.hasTag(cell, .float));
    const boxed: *const layouts.BoxedFloat = @ptrFromInt(layouts.UNTAG(cell));
    return boxed.n;
}

// --- Tests ---

test "boxed floats round trip through the nursery bit for bit" {
    const data_heap_mod = @import("data_heap.zig");
    const testing = std.testing;
    const vm = try FactorVM.init(testing.allocator);
    vm.vm_asm.ctx = try vm.newContext();
    vm.vm_asm.spare_ctx = try vm.newContext();
    defer {
        vm.cards_array = null;
        vm.decks_array = null;
        vm.deinit();
    }
    const heap = try data_heap_mod.DataHeap.init(testing.allocator, 64 * 1024, 64 * 1024, 64 * 1024);
    defer heap.deinit();
    vm.setDataHeap(heap);

    const values = [_]f64{
        0.0,
        -0.0,
        1.5,
        -2.25,
        std.math.floatMax(f64),
        -std.math.floatMax(f64),
        std.math.floatMin(f64),
        std.math.floatTrueMin(f64),
        std.math.inf(f64),
        -std.math.inf(f64),
        std.math.nan(f64),
        -std.math.nan(f64),
        @as(f64, @bitCast(@as(u64, 0x7ff8_dead_beef_0001))),
    };
    var previous: ?*layouts.BoxedFloat = null;
    for (values) |v| {
        const boxed = try allocBoxedFloat(vm, v);
        const tagged = layouts.tagFloat(boxed);
        try testing.expect(layouts.hasTag(tagged, .float));
        try testing.expectEqual(@as(u64, @bitCast(v)), @as(u64, @bitCast(untagFloat(tagged))));
        const obj: *const layouts.Object = @ptrCast(boxed);
        try testing.expectEqual(layouts.TypeTag.float, obj.getType());
        try testing.expect(vm.vm_asm.nursery.contains(@ptrCast(boxed)));
        // Each box is a distinct, alignment-sized object.
        if (previous) |prev| {
            try testing.expectEqual(layouts.alignCell(@sizeOf(layouts.BoxedFloat), layouts.data_alignment), @intFromPtr(boxed) - @intFromPtr(prev));
        }
        previous = boxed;
    }
}
