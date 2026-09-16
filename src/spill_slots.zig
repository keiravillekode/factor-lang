// spill_slots.zig - Shared spill-slot traversal for callstack GC roots
//
// Handles the derived-pointer protocol:
// 1) subtract base pointers from derived pointers
// 2) visit GC roots selected by the callsite bitmap
// 3) add base pointers back to derived pointers

const code_blocks = @import("code_blocks.zig");
const layouts = @import("layouts.zig");

const Cell = layouts.Cell;

pub fn visit(
    comptime Ctx: type,
    stack_pointer: [*]Cell,
    gc_info: *const code_blocks.GcInfo,
    callsite: u32,
    ctx: Ctx,
    comptime visitSlotFn: fn (*Cell, Ctx) void,
) void {
    const bitmap = gc_info.gcInfoBitmap();

    var spill_slot: u32 = 0;
    while (spill_slot < gc_info.derived_root_count) : (spill_slot += 1) {
        const base_pointer = gc_info.lookupBasePointer(callsite, spill_slot);
        if (base_pointer != @as(u32, 0xFFFFFFFF)) {
            stack_pointer[spill_slot] -%= stack_pointer[base_pointer];
        }
    }

    const callsite_roots = gc_info.callsiteGcRoots(callsite);
    spill_slot = 0;
    while (spill_slot < gc_info.gc_root_count) : (spill_slot += 1) {
        if (code_blocks.isBitmapSet(bitmap, callsite_roots + spill_slot)) {
            visitSlotFn(&stack_pointer[spill_slot], ctx);
        }
    }

    spill_slot = 0;
    while (spill_slot < gc_info.derived_root_count) : (spill_slot += 1) {
        const base_pointer = gc_info.lookupBasePointer(callsite, spill_slot);
        if (base_pointer != @as(u32, 0xFFFFFFFF)) {
            stack_pointer[spill_slot] +%= stack_pointer[base_pointer];
        }
    }
}

// --- Tests ---

const std = @import("std");
const testing = std.testing;

// Hand-built GcInfo: 4 GC roots, 2 derived roots, 2 callsites with return
// address offsets 0x10 and 0x20. Callsite 1 has derived root 0 based on
// spill slot 2 and GC roots at slots 0 and 2 (bitmap bits 4 and 6 of the
// single bitmap byte, 0x50); callsite 0 has nothing.
// The layout, from the end of the code block backwards, is: GcInfo,
// return_addresses[2], base_pointer_map[2 * 2], bitmap bytes.
const GcInfoWords = struct {
    words: [10]u32 align(8),

    fn init() GcInfoWords {
        var g: GcInfoWords = .{ .words = .{0} ** 10 };
        g.words[0] = @as(u32, 0x50) << 24;
        g.words[1] = 0xFFFFFFFF;
        g.words[2] = 0xFFFFFFFF;
        g.words[3] = 2;
        g.words[4] = 0xFFFFFFFF;
        g.words[5] = 0x10;
        g.words[6] = 0x20;
        g.words[7] = 4; // gc_root_count
        g.words[8] = 2; // derived_root_count
        g.words[9] = 2; // return_address_count
        return g;
    }

    fn info(self: *const GcInfoWords) *const code_blocks.GcInfo {
        return @ptrCast(&self.words[7]);
    }
};

test "GcInfo accessors locate the tables stored before the header" {
    const g = GcInfoWords.init();
    const info = g.info();
    try testing.expectEqual(@as(u32, 4), info.callsiteBitmapSize());
    try testing.expectEqual(@as(u32, 8), info.totalBitmapSize());
    try testing.expectEqual(@as(u32, 1), info.totalBitmapBytes());
    try testing.expectEqual(@intFromPtr(&g.words[5]), @intFromPtr(info.returnAddresses()));
    try testing.expectEqual(@intFromPtr(&g.words[1]), @intFromPtr(info.basePointerMap()));
    try testing.expectEqual(@intFromPtr(&g.words[1]) - 1, @intFromPtr(info.gcInfoBitmap()));
    try testing.expectEqual(@as(u8, 0x50), info.gcInfoBitmap()[0]);
    try testing.expectEqual(@as(u32, 0), info.callsiteGcRoots(0));
    try testing.expectEqual(@as(u32, 4), info.callsiteGcRoots(1));
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), info.lookupBasePointer(0, 0));
    try testing.expectEqual(@as(u32, 2), info.lookupBasePointer(1, 0));
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), info.lookupBasePointer(1, 1));
    try testing.expectEqual(@as(?u32, 0), info.returnAddressIndex(0x10));
    try testing.expectEqual(@as(?u32, 1), info.returnAddressIndex(0x20));
    try testing.expectEqual(@as(?u32, null), info.returnAddressIndex(0x18));

    const bitmap = info.gcInfoBitmap();
    try testing.expect(!code_blocks.isBitmapSet(bitmap, 0));
    try testing.expect(code_blocks.isBitmapSet(bitmap, 4));
    try testing.expect(!code_blocks.isBitmapSet(bitmap, 5));
    try testing.expect(code_blocks.isBitmapSet(bitmap, 6));
    try testing.expect(!code_blocks.isBitmapSet(bitmap, 7));
}

const Recorder = struct {
    seen: [4]Cell = undefined,
    count: usize = 0,
    move_base_to: Cell,

    fn visitSlot(slot: *Cell, self: *Recorder) void {
        self.seen[self.count] = slot.*;
        self.count += 1;
        // Pretend the GC moved the object the base pointer refers to.
        if (slot.* == 0x1000) slot.* = self.move_base_to;
    }
};

test "visit rebases derived pointers around the visited roots" {
    const g = GcInfoWords.init();
    const info = g.info();
    const base: Cell = 0x1000;

    // Slot 0 is a derived pointer 8 bytes into the object at slot 2 (the
    // base); slots 1 and 3 are not roots at callsite 1.
    var stack: [4]Cell = .{ base + 8, 1234, base, 5 };
    var rec = Recorder{ .move_base_to = 0x2000 };
    visit(*Recorder, &stack, info, 1, &rec, Recorder.visitSlot);

    try testing.expectEqual(@as(usize, 2), rec.count);
    // The derived slot is visited as an offset, the base as a pointer.
    try testing.expectEqual(@as(Cell, 8), rec.seen[0]);
    try testing.expectEqual(base, rec.seen[1]);
    // Afterwards the derived pointer follows the moved base.
    try testing.expectEqual(@as(Cell, 0x2000 + 8), stack[0]);
    try testing.expectEqual(@as(Cell, 1234), stack[1]);
    try testing.expectEqual(@as(Cell, 0x2000), stack[2]);
    try testing.expectEqual(@as(Cell, 5), stack[3]);

    // Callsite 0 has no roots and no base pointers: nothing is touched.
    var untouched: [4]Cell = .{ 1, 2, 3, 4 };
    var rec0 = Recorder{ .move_base_to = 0 };
    visit(*Recorder, &untouched, info, 0, &rec0, Recorder.visitSlot);
    try testing.expectEqual(@as(usize, 0), rec0.count);
    try testing.expectEqual([4]Cell{ 1, 2, 3, 4 }, untouched);
}

test "visit leaves a derived pointer alone when its base is unchanged" {
    const g = GcInfoWords.init();
    const info = g.info();
    var stack: [4]Cell = .{ 0x1000 + 0x40, 0, 0x1000, 0 };
    var rec = Recorder{ .move_base_to = 0x1000 };
    visit(*Recorder, &stack, info, 1, &rec, Recorder.visitSlot);
    try testing.expectEqual(@as(Cell, 0x1040), stack[0]);
    try testing.expectEqual(@as(Cell, 0x40), rec.seen[0]);
}
