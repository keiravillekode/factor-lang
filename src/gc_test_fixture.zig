// gc_test_fixture.zig - test-only scaffolding shared by the mark, sweep and
// compaction unit tests. Builds a bare VM with a small data heap and no code
// heap, and offers helpers to hand-allocate typed objects in tenured space or
// the nursery.
//
// Nothing here is referenced by production code.

const std = @import("std");

const data_heap_mod = @import("data_heap.zig");
const gc_mod = @import("gc.zig");
const layouts = @import("layouts.zig");
const mark_mod = @import("mark.zig");
const slot_visitor = @import("slot_visitor.zig");
const vm_mod = @import("vm.zig");

const Cell = layouts.Cell;

// Tenured must stay well above young + aging: collectFull treats
// free_space <= young + aging as "low memory" and grows the heap instead of
// compacting. Sizes are rounded up to deck_size (256 KB) by DataHeap.init.
pub const young_size: Cell = 64 * 1024;
pub const aging_size: Cell = 64 * 1024;
pub const tenured_size: Cell = 2 * 1024 * 1024;

pub const array_tag: Cell = @intFromEnum(layouts.TypeTag.array);
pub const tuple_tag: Cell = @intFromEnum(layouts.TypeTag.tuple);
pub const byte_array_tag: Cell = @intFromEnum(layouts.TypeTag.byte_array);
pub const string_tag: Cell = @intFromEnum(layouts.TypeTag.string);

pub fn arraySize(capacity: Cell) Cell {
    return layouts.alignCell(@sizeOf(layouts.Array) + capacity * @sizeOf(Cell), layouts.data_alignment);
}

pub fn byteArraySize(capacity: Cell) Cell {
    return layouts.alignCell(@sizeOf(layouts.ByteArray) + capacity, layouts.data_alignment);
}

pub fn stringSize(length: Cell) Cell {
    return layouts.alignCell(@sizeOf(layouts.String) + length, layouts.data_alignment);
}

pub fn tupleSize(slots: Cell) Cell {
    return layouts.alignCell(@sizeOf(layouts.Tuple) + slots * @sizeOf(Cell), layouts.data_alignment);
}

// A tuple layout is an array-tagged object: header, capacity, klass, size,
// echelon, then (superclass, hashcode) pairs. We always emit one pair.
pub const tuple_layout_capacity: Cell = 5;
pub const tuple_layout_size: Cell = arraySize(tuple_layout_capacity);

pub const Fixture = struct {
    vm: *vm_mod.FactorVM,
    heap: *data_heap_mod.DataHeap,
    gc: gc_mod.GarbageCollector,
    bump: Cell,

    const Self = @This();

    pub fn init(self: *Self) !void {
        const allocator = std.testing.allocator;
        self.bump = 0;
        self.vm = try vm_mod.FactorVM.init(allocator);
        self.vm.vm_asm.ctx = try self.vm.newContext();
        self.vm.vm_asm.spare_ctx = try self.vm.newContext();
        self.heap = try data_heap_mod.DataHeap.init(allocator, young_size, aging_size, tenured_size);
        self.vm.setDataHeap(self.heap);
        self.gc = gc_mod.GarbageCollector.init(allocator, self.vm, self.heap);
        self.vm.gc = &self.gc;
    }

    pub fn deinit(self: *Self) void {
        // vm.deinit would deinit vm.gc itself; we own it, so detach first.
        self.vm.gc = null;
        self.gc.deinit();
        // Cards/decks belong to the heap, not the VM.
        self.vm.cards_array = null;
        self.vm.decks_array = null;
        self.vm.deinit();
        self.heap.deinit();
    }

    pub fn tenured(self: *Self) *data_heap_mod.TenuredSpace {
        return &self.heap.tenured;
    }

    /// Carve the next object sequentially from the start of tenured space so
    /// tests get deterministic, address-ordered placement (the free list's
    /// page-promotion policy hands out small blocks from the top of a page
    /// downwards, which would scramble allocation order vs. address order).
    /// The free list is re-seeded to cover exactly the untouched tail, so
    /// accounting and later allocations (e.g. promotion) stay consistent.
    fn allotTenuredRaw(self: *Self, type_tag: layouts.TypeTag, size: Cell) Cell {
        const tenured_space = &self.heap.tenured;
        const addr = tenured_space.start + self.bump;
        std.debug.assert(addr + size <= tenured_space.end);
        self.bump += size;
        tenured_space.object_start.recordAllocation(addr);
        tenured_space.free_list.initialFreeList(self.bump);
        const obj: *layouts.Object = @ptrFromInt(addr);
        obj.initialize(type_tag);
        return addr;
    }

    /// Tenured array of `capacity` cells, every cell set to `fill`. Returns the tagged pointer.
    pub fn tenuredArray(self: *Self, capacity: Cell, fill: Cell) Cell {
        const addr = self.allotTenuredRaw(.array, arraySize(capacity));
        const arr: *layouts.Array = @ptrFromInt(addr);
        arr.capacity = layouts.tagFixnum(@intCast(capacity));
        @memset(arr.data()[0..capacity], fill);
        return addr | array_tag;
    }

    /// Tenured byte array holding a copy of `bytes`. Returns the tagged pointer.
    pub fn tenuredByteArray(self: *Self, bytes: []const u8) Cell {
        const addr = self.allotTenuredRaw(.byte_array, byteArraySize(bytes.len));
        const ba: *layouts.ByteArray = @ptrFromInt(addr);
        ba.capacity = layouts.tagFixnum(@intCast(bytes.len));
        @memcpy(ba.data()[0..bytes.len], bytes);
        return addr | byte_array_tag;
    }

    /// Tenured string holding a copy of `text`, aux = f, hashcode = 0. Returns the tagged pointer.
    pub fn tenuredString(self: *Self, text: []const u8) Cell {
        const addr = self.allotTenuredRaw(.string, stringSize(text.len));
        const str: *layouts.String = @ptrFromInt(addr);
        str.length = layouts.tagFixnum(@intCast(text.len));
        str.aux = layouts.false_object;
        str.hashcode_field = layouts.tagFixnum(0);
        @memcpy(str.data()[0..text.len], text);
        return addr | string_tag;
    }

    /// Tenured tuple layout describing tuples with `slots` slots. Returns the
    /// array-tagged pointer, which is what a tuple's `layout` field stores.
    pub fn tenuredTupleLayout(self: *Self, slots: Cell) Cell {
        const addr = self.allotTenuredRaw(.array, tuple_layout_size);
        const layout: *layouts.TupleLayout = @ptrFromInt(addr);
        layout.capacity = layouts.tagFixnum(@intCast(tuple_layout_capacity));
        layout.klass = layouts.false_object;
        layout.size = layouts.tagFixnum(@intCast(slots));
        layout.echelon = layouts.tagFixnum(0);
        layout.data()[0] = layouts.false_object;
        layout.data()[1] = layouts.tagFixnum(0);
        return addr | array_tag;
    }

    /// Tenured tuple using `layout_tagged` (from tenuredTupleLayout); slots set to `fill`.
    pub fn tenuredTuple(self: *Self, layout_tagged: Cell, fill: Cell) Cell {
        const layout: *const layouts.TupleLayout = @ptrFromInt(layouts.UNTAG(layout_tagged));
        const slots = layouts.untagFixnumUnsigned(layout.size);
        const addr = self.allotTenuredRaw(.tuple, tupleSize(slots));
        const tuple: *layouts.Tuple = @ptrFromInt(addr);
        tuple.layout = layout_tagged;
        @memset(tuple.data()[0..slots], fill);
        return addr | tuple_tag;
    }

    /// Nursery array allocated through the VM's own bump allocator. Returns the tagged pointer.
    pub fn nurseryArray(self: *Self, capacity: Cell, fill: Cell) Cell {
        return self.vm.allotArray(capacity, fill) orelse @panic("test nursery exhausted");
    }

    /// Run the full-GC mark phase exactly the way gc.markPhaseFull_ does, but
    /// without resetting the nursery/aging afterwards so tests can inspect
    /// forwarding pointers left behind.
    pub fn fullMark(self: *Self) void {
        self.heap.tenured.clearMarks();
        self.gc.mark_stack.clearRetainingCapacity();
        self.heap.nursery.here = self.vm.vm_asm.nursery.here;

        const nursery = &self.vm.vm_asm.nursery;
        const aging = &self.heap.aging;
        const aging_semi = &self.heap.aging_semispace;
        var destination = slot_visitor.CopyingDestination{
            .tenured_target = &self.heap.tenured,
            .mark_stack = null,
            .source_start = nursery.start,
            .source_end = nursery.end,
            .source2_start = aging.start,
            .source2_end = aging.end,
            .source3_start = aging_semi.start,
            .source3_end = aging_semi.end,
            .code_heap = self.vm.code,
        };
        var ctx = mark_mod.FullMarkContext{
            .gc = &self.gc,
            .destination = &destination,
            .tenured = &self.heap.tenured,
        };
        mark_mod.fullMarkAllRoots(&self.gc, &ctx);
        mark_mod.fullDrainMarkStack(&self.gc, &ctx);
        std.debug.assert(!destination.allocation_failed);
    }

    pub fn isMarked(self: *Self, tagged: Cell) bool {
        return self.heap.tenured.isMarked(layouts.UNTAG(tagged));
    }

    pub fn inTenured(self: *Self, tagged: Cell) bool {
        return self.heap.tenured.contains(layouts.UNTAG(tagged));
    }

    pub fn inNursery(self: *Self, tagged: Cell) bool {
        const addr = layouts.UNTAG(tagged);
        return addr >= self.heap.nursery.start and addr < self.heap.nursery.end;
    }

    pub fn cardByte(self: *Self, slot: *const Cell) u8 {
        const slot_addr = @intFromPtr(slot);
        const card_ptr: *u8 = @ptrFromInt(self.vm.vm_asm.cards_offset +% (slot_addr >> @intCast(vm_mod.card_bits)));
        return card_ptr.*;
    }
};

pub fn arrayAt(tagged: Cell) *layouts.Array {
    return @ptrFromInt(layouts.UNTAG(tagged));
}

pub fn objectAt(tagged: Cell) *layouts.Object {
    return @ptrFromInt(layouts.UNTAG(tagged));
}
