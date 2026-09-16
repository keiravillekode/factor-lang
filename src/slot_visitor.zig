const std = @import("std");
const builtin = @import("builtin");
const callstack_lookup = @import("callstack_lookup.zig");
const code_blocks = @import("code_blocks.zig");
const contexts = @import("contexts.zig");
const code_heap_mod = @import("code_heap.zig");
const data_heap_mod = @import("data_heap.zig");
const layouts = @import("layouts.zig");
const objects = @import("objects.zig");
const spill_slots = @import("spill_slots.zig");
const Cell = layouts.Cell;
const Object = layouts.Object;

fn visitInfoForFixup(comptime Fixup: type, fixup: *Fixup, address: Cell) layouts.ObjectVisitInfo {
    const obj: *Object = @ptrFromInt(address);

    return switch (obj.getType()) {
        .tuple => blk: {
            const tuple: *layouts.Tuple = @ptrFromInt(address);
            const layout_addr = if (@hasDecl(Fixup, "resolveTupleLayout"))
                fixup.resolveTupleLayout(tuple.layout)
            else
                layouts.followForwardingPointers(tuple.layout);
            std.debug.assert((layout_addr & 7) == 0);
            const layout: *layouts.TupleLayout = @ptrFromInt(layout_addr);
            const tuple_size = layouts.untagFixnumUnsigned(layout.size);
            break :blk .{
                .type = .tuple,
                .slot_count = 1 + tuple_size,
                .size = layouts.alignCell(@sizeOf(layouts.Tuple) + tuple_size * @sizeOf(Cell), layouts.data_alignment),
            };
        },
        else => layouts.objectVisitInfoFromAddress(address),
    };
}

pub fn visitDataObjectSlots(comptime Fixup: type, fixup: *Fixup, address: Cell) Cell {
    const obj: *Object = @ptrFromInt(address);
    if (obj.isFree()) return 0;

    const info = visitInfoForFixup(Fixup, fixup, address);
    if (info.size == 0) return 0;

    switch (info.type) {
        .callstack => {
            if (@hasDecl(Fixup, "visitCallstackObject")) {
                const cs: *layouts.Callstack = @ptrFromInt(address);
                fixup.visitCallstackObject(cs);
            }
            return info.size;
        },
        .fixnum, .f => return 0,
        else => {},
    }

    if (info.slot_count > 0) {
        if (@hasDecl(Fixup, "ensureSlotCapacity")) fixup.ensureSlotCapacity(info.slot_count);
        const slots: [*]Cell = @ptrFromInt(address + @sizeOf(Cell));
        for (0..info.slot_count) |i| {
            fixup.visitSlot(&slots[i]);
        }
    }

    switch (info.type) {
        .quotation => {
            if (@hasDecl(Fixup, "visitEntryPoint")) {
                const quot: *layouts.Quotation = @ptrFromInt(address);
                fixup.visitEntryPoint(quot.entry_point);
            }
        },
        .word => {
            if (@hasDecl(Fixup, "visitEntryPoint")) {
                const word_obj: *layouts.Word = @ptrFromInt(address);
                fixup.visitEntryPoint(word_obj.entry_point);
            }
        },
        .alien => {
            const alien: *layouts.Alien = @ptrFromInt(address);
            alien.updateAddress();
        },
        else => {},
    }

    return info.size;
}

pub const CopyingDestination = struct {
    const Self = @This();

    source_start: Cell = 0,
    source_end: Cell = 0,
    bump_here: ?*Cell = null,
    bump_end: Cell = 0,
    bump_object_start: *@import("object_start_map.zig").ObjectStartMap = undefined,
    allocation_failed: bool = false,

    source2_start: Cell = 0,
    source2_end: Cell = 0,
    source3_start: Cell = 0,
    source3_end: Cell = 0,
    source4_start: Cell = 0,
    source4_end: Cell = 0,
    // Promotion target: where survivors are copied when bump_here is null (no
    // semispace finger). A typed field, not a fn-pointer, so the copy hot path
    // has no indirect calls.
    tenured_target: ?*data_heap_mod.TenuredSpace = null,
    // Cheney worklist: copied objects pushed here for later slot scanning.
    // null for bump/semispace collectors (which use a finger) and for the
    // full-mark copy path (which drains via its own mark phase).
    mark_stack: ?*std.ArrayList(Cell) = null,
    mark_stack_allocator: std.mem.Allocator = undefined,
    code_heap: ?*code_heap_mod.CodeHeap = null,

    pub fn allocate(self: *CopyingDestination, size: Cell) ?Cell {
        if (self.bump_here) |here_ptr| {
            const h = here_ptr.*;
            const aligned_size = layouts.alignCell(size, layouts.data_alignment);
            if (h + aligned_size > self.bump_end) {
                return null;
            }
            here_ptr.* = h + aligned_size;
            self.bump_object_start.recordObjectStart(h);
            return h;
        }
        if (self.tenured_target) |space| return space.allocate(size);
        return null;
    }

    fn inSourceGeneration(self: *const CopyingDestination, addr: Cell) bool {
        if (addr >= self.source_start and addr < self.source_end) return true;
        if (self.source2_end != 0) {
            if (addr >= self.source2_start and addr < self.source2_end) return true;
            if (self.source3_end != 0) {
                if (addr >= self.source3_start and addr < self.source3_end) return true;
                if (self.source4_end != 0 and addr >= self.source4_start and addr < self.source4_end) return true;
            }
        }
        return false;
    }

    pub fn copy(self: *CopyingDestination, old_addr: Cell) Cell {
        const original_untagged = layouts.UNTAG(old_addr);

        if (!self.inSourceGeneration(original_untagged)) {
            return old_addr;
        }

        return copyInSourceGeneration(self, old_addr, original_untagged);
    }

    noinline fn copyInSourceGeneration(
        self: *CopyingDestination,
        old_addr: Cell,
        original_untagged: Cell,
    ) Cell {
        var obj: *Object = @ptrFromInt(original_untagged);

        var untagged = original_untagged;
        if (obj.isForwardingPointer()) {
            while (obj.isForwardingPointer()) {
                obj = obj.forwardingPointer();
            }
            untagged = @intFromPtr(obj);

            if (!self.inSourceGeneration(untagged)) {
                return untagged | layouts.TAG(old_addr);
            }
        }

        const size = layouts.objectVisitInfoFromAddress(untagged).size;

        const new_addr = self.allocate(size) orelse {
            self.allocation_failed = true;
            return old_addr;
        };

        if (new_addr != untagged) {
            const src: [*]u8 = @ptrFromInt(untagged);
            const dst: [*]u8 = @ptrFromInt(new_addr);
            @memcpy(dst[0..size], src[0..size]);
        } else {
            return old_addr;
        }

        obj.forwardTo(@ptrFromInt(new_addr));

        // Cheney worklist push: queue the copied object for later slot scanning.
        if (self.mark_stack) |ms| {
            ms.append(self.mark_stack_allocator, new_addr) catch @panic("Mark stack overflow");
        }

        return new_addr | layouts.TAG(old_addr);
    }
};

pub const CopyFixup = struct {
    destination: *CopyingDestination,

    pub fn visitSlot(self: *@This(), slot: *Cell) void {
        const value = slot.*;
        if (!layouts.isImmediate(value)) {
            const new_value = self.destination.copy(value);
            if (new_value != value) slot.* = new_value;
        }
    }

    pub fn visitCallstackObject(self: *@This(), stack: *layouts.Callstack) void {
        const code_heap = self.destination.code_heap orelse return;
        visitCallstackObjectRoots(CopyFixup, self, code_heap, stack);
    }
};

pub fn traceAndCopyReturnSize(address: Cell, destination: *CopyingDestination) Cell {
    var fixup = CopyFixup{ .destination = destination };
    return visitDataObjectSlots(CopyFixup, &fixup, address);
}

/// Walk a *callstack object's* frames and apply `fixup.visitSlot(*Cell)` to
/// every spilled object pointer. If `Fixup` declares `visitCodeBlockOwner`, it
/// is also called for each frame's owning code block (the full/mark collector
/// needs this to keep the block live across a code-heap sweep; the copying
/// collector does not and omits the method). Callstack objects store frames
/// relative to the object body; on arm64 the relative frame size is at slot 0
/// and the return address at +8, on x86-64 the return address is at +0. Shared
/// by the copying and full-mark collectors so this frame convention — and the
/// GC-safety of promoting spilled referents — lives in exactly one place.
pub fn visitCallstackObjectRoots(
    comptime Fixup: type,
    fixup: *Fixup,
    code_heap: *code_heap_mod.CodeHeap,
    stack: *layouts.Callstack,
) void {
    var lookup = callstack_lookup.Lookup.init(code_heap) orelse return;
    const frame_length = layouts.untagFixnumUnsigned(stack.length);
    if (frame_length == 0) return;

    const LEAF_FRAME_SIZE: Cell = code_blocks.CodeBlock.LEAF_FRAME_SIZE;
    const is_arm64 = builtin.cpu.arch == .aarch64;
    var frame_offset: Cell = 0;

    while (frame_offset < frame_length) {
        const frame_top = stack.frameTopAt(frame_offset);

        // arm64 callstack objects store the (relative) frame size at slot 0 and
        // the return address at +8; x86-64 stores the return address at +0.
        const arm_frame_size: Cell = if (is_arm64) @as(*const Cell, @ptrFromInt(frame_top)).* else 0;
        if (is_arm64 and (arm_frame_size == 0 or frame_offset + arm_frame_size > frame_length)) break;

        const addr = @as(*const Cell, @ptrFromInt(frame_top + contexts.FRAME_RETURN_ADDRESS)).*;
        if (addr == 0) break;

        const owner = lookup.ownerForAddressUnsafe(addr) orelse {
            frame_offset += if (is_arm64) arm_frame_size else LEAF_FRAME_SIZE;
            continue;
        };

        const advance = if (is_arm64) arm_frame_size else owner.stackFrameSizeForAddress(addr);

        if (comptime @hasDecl(Fixup, "visitCodeBlockOwner")) {
            fixup.visitCodeBlockOwner(owner);
        }

        if (owner.blockGcInfo()) |gc_info| {
            const return_address_offset: u32 = @intCast(owner.offset(addr));
            if (lookup.callsiteIndex(gc_info, return_address_offset)) |callsite| {
                // A frame's spilled roots number at most frame_size/cell. Fixups
                // that push assume-capacity (the full-mark collector) must have
                // room reserved first, since visitDataObjectSlots does not
                // pre-ensure capacity for callstack objects the way it does for
                // ordinary slot loops.
                if (comptime @hasDecl(Fixup, "ensureSlotCapacity")) {
                    fixup.ensureSlotCapacity(advance / @sizeOf(Cell));
                }
                const stack_pointer: [*]Cell = @ptrFromInt(frame_top);
                const Visit = struct {
                    fn slot(slot_ptr: *Cell, fx: *Fixup) void {
                        fx.visitSlot(slot_ptr);
                    }
                };
                spill_slots.visit(*Fixup, stack_pointer, gc_info, callsite, fixup, Visit.slot);
            }
        }

        frame_offset += advance;
    }
}

/// Walk the live native callstack of a context (between `callstack_top` and
/// `callstack_bottom`) and apply `fixup.visitSlot(*Cell)` to every spilled
/// object pointer. This is the exact arm64-aware frame walk used by the GC's
/// visitCallstack, factored out so non-GC root scanners (primitive_become)
/// reuse one validated implementation instead of re-deriving the frame
/// conventions. The caller must pass the context's *saved* callstack pointers
/// (valid after a GC/safepoint save) and a live code heap.
pub fn visitLiveCallstackRoots(
    comptime Fixup: type,
    fixup: *Fixup,
    code_heap: *code_heap_mod.CodeHeap,
    callstack_top: Cell,
    callstack_bottom: Cell,
) void {
    var lookup = callstack_lookup.Lookup.init(code_heap) orelse return;

    var top = callstack_top;
    const bottom = callstack_bottom;
    if (top == 0 or bottom == 0 or top >= bottom) return;

    const LEAF_FRAME_SIZE: Cell = code_blocks.CodeBlock.LEAF_FRAME_SIZE;
    const is_arm64 = builtin.cpu.arch == .aarch64;

    while (top < bottom) {
        // Return address: frame_top+0 on x86-64, frame_top+8 on arm64.
        const addr = @as(*const Cell, @ptrFromInt(top + contexts.FRAME_RETURN_ADDRESS)).*;
        if (addr == 0) break;

        // arm64 frames are chained: *(top) is the predecessor frame top.
        const next_top: Cell = if (is_arm64) @as(*const Cell, @ptrFromInt(top)).* else 0;

        const owner = lookup.ownerForAddressUnsafe(addr) orelse {
            if (is_arm64) {
                if (next_top <= top) break;
                top = next_top;
            } else {
                top += LEAF_FRAME_SIZE;
            }
            continue;
        };

        // Full-mark GC needs the frame's code block kept live (return addresses
        // alone are not heap roots). Optional so become/copy paths can omit it.
        if (comptime @hasDecl(Fixup, "visitCodeBlockOwner")) {
            fixup.visitCodeBlockOwner(owner);
        }

        if (owner.blockGcInfo()) |gc_info| {
            const return_address_offset: u32 = @intCast(owner.offset(addr));
            if (lookup.callsiteIndex(gc_info, return_address_offset)) |callsite| {
                const stack_pointer: [*]Cell = @ptrFromInt(top);
                const Visit = struct {
                    fn slot(slot_ptr: *Cell, fx: *Fixup) void {
                        fx.visitSlot(slot_ptr);
                    }
                };
                spill_slots.visit(*Fixup, stack_pointer, gc_info, callsite, fixup, Visit.slot);
            }
        } else {
            lookup.cached_gc_info = null;
            lookup.cached_callsite_index = null;
        }

        if (is_arm64) {
            if (next_top <= top) break;
            top = next_top;
        } else {
            top += callstack_lookup.Lookup.frameSizeFromAddress(owner, addr);
        }
    }
}

// Get size of object for iteration purposes
pub fn objectSize(address: Cell) Cell {
    return layouts.objectVisitInfoFromAddress(address).size;
}

// Iterate over all objects in a memory range
pub const ObjectIterator = struct {
    current: Cell,
    end: Cell,

    const Self = @This();

    pub fn init(start: Cell, end: Cell) Self {
        return Self{
            .current = start,
            .end = end,
        };
    }

    pub fn next(self: *Self) ?Cell {
        while (self.current < self.end) {
            const addr = self.current;
            const header: Cell = @as(*const Cell, @ptrFromInt(addr)).*;

            if (header & 1 == 1) {
                // Free block - size encoded in header for both regular
                // free blocks and gap blocks (< min_block_size).
                const size = header & ~@as(Cell, 7);
                if (size == 0) return null;
                self.current += size;
                continue;
            }

            if (header == 0) return null;
            const size = objectSize(addr);
            if (size == 0) return null;
            self.current += size;
            return addr;
        }
        return null;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const vm_mod = @import("vm.zig");
const gc_fixture = @import("gc_test_fixture.zig");

fn tfx(n: layouts.Fixnum) Cell {
    return layouts.tagFixnum(n);
}

fn hdr(tag: layouts.TypeTag) Cell {
    return @as(Cell, @intFromEnum(tag)) << 2;
}

// Records every slot value handed to visitSlot, plus the optional callbacks.
const Recorder = struct {
    seen: [16]Cell = undefined,
    count: usize = 0,
    entry_points: [4]Cell = undefined,
    entry_count: usize = 0,
    callstack_visits: usize = 0,
    capacity_hint: Cell = 0,

    pub fn visitSlot(self: *Recorder, slot: *Cell) void {
        self.seen[self.count] = slot.*;
        self.count += 1;
    }

    pub fn visitEntryPoint(self: *Recorder, entry_point: Cell) void {
        self.entry_points[self.entry_count] = entry_point;
        self.entry_count += 1;
    }

    pub fn visitCallstackObject(self: *Recorder, _: *layouts.Callstack) void {
        self.callstack_visits += 1;
    }

    pub fn ensureSlotCapacity(self: *Recorder, n: Cell) void {
        self.capacity_hint = n;
    }

    fn slots(self: *const Recorder) []const Cell {
        return self.seen[0..self.count];
    }
};

// Minimal fixup with only visitSlot, so the optional hooks stay unused.
const SlotOnly = struct {
    count: usize = 0,

    pub fn visitSlot(self: *SlotOnly, _: *Cell) void {
        self.count += 1;
    }
};

test "visitDataObjectSlots visits an array's capacity and elements" {
    var buf: [6]Cell align(16) = .{ hdr(.array), tfx(3), tfx(1), tfx(2), tfx(3), 0 };
    var rec = Recorder{};
    const size = visitDataObjectSlots(Recorder, &rec, @intFromPtr(&buf));
    try testing.expectEqual(@as(Cell, 48), size);
    try testing.expectEqualSlices(Cell, &.{ tfx(3), tfx(1), tfx(2), tfx(3) }, rec.slots());
    try testing.expectEqual(@as(Cell, 4), rec.capacity_hint);
    try testing.expectEqual(@as(usize, 0), rec.entry_count);
    try testing.expectEqual(@as(usize, 0), rec.callstack_visits);
}

test "visitDataObjectSlots visits string metadata but not string bytes" {
    var buf: [6]Cell align(16) = .{ hdr(.string), tfx(4), layouts.false_object, tfx(77), 0, 0 };
    const str: *layouts.String = @ptrCast(&buf);
    @memcpy(str.data()[0..4], "abcd");
    var rec = Recorder{};
    const size = visitDataObjectSlots(Recorder, &rec, @intFromPtr(&buf));
    try testing.expectEqual(@as(Cell, 48), size);
    try testing.expectEqualSlices(Cell, &.{ tfx(4), layouts.false_object, tfx(77) }, rec.slots());
}

test "visitDataObjectSlots skips byte arrays, bignums and floats but reports their size" {
    var ba: [4]Cell align(16) = .{ hdr(.byte_array), tfx(5), 0, 0 };
    var bn: [4]Cell align(16) = .{ hdr(.bignum), tfx(2), 0, 7 };
    var fl: [2]Cell align(16) = .{ hdr(.float), 0 };
    var rec = Recorder{};
    try testing.expectEqual(@as(Cell, 32), visitDataObjectSlots(Recorder, &rec, @intFromPtr(&ba)));
    try testing.expectEqual(@as(Cell, 32), visitDataObjectSlots(Recorder, &rec, @intFromPtr(&bn)));
    try testing.expectEqual(@as(Cell, 16), visitDataObjectSlots(Recorder, &rec, @intFromPtr(&fl)));
    try testing.expectEqual(@as(usize, 0), rec.count);
}

test "visitDataObjectSlots returns 0 for free blocks without visiting" {
    var buf: [2]Cell align(16) = .{ hdr(.array) | 1, tfx(0) };
    var rec = Recorder{};
    try testing.expectEqual(@as(Cell, 0), visitDataObjectSlots(Recorder, &rec, @intFromPtr(&buf)));
    try testing.expectEqual(@as(usize, 0), rec.count);
}

test "visitDataObjectSlots visits a tuple's layout and slots through the layout size" {
    var layout_buf: [8]Cell align(16) = .{ hdr(.array), tfx(5), layouts.false_object, tfx(2), tfx(0), layouts.false_object, tfx(0), 0 };
    const layout_tagged = @intFromPtr(&layout_buf) | @intFromEnum(layouts.TypeTag.array);
    var buf: [4]Cell align(16) = .{ hdr(.tuple), layout_tagged, tfx(11), tfx(22) };
    var rec = Recorder{};
    const size = visitDataObjectSlots(Recorder, &rec, @intFromPtr(&buf));
    try testing.expectEqual(@as(Cell, 32), size);
    try testing.expectEqualSlices(Cell, &.{ layout_tagged, tfx(11), tfx(22) }, rec.slots());
}

test "visitDataObjectSlots asks the fixup to resolve a tuple layout when it can" {
    // Two layouts: the tuple points at a 3-slot one, but the fixup redirects to
    // a 1-slot layout, as a compaction fixup does for a moved layout object.
    var big_layout: [8]Cell align(16) = .{ hdr(.array), tfx(5), layouts.false_object, tfx(3), tfx(0), layouts.false_object, tfx(0), 0 };
    var small_layout: [8]Cell align(16) = .{ hdr(.array), tfx(5), layouts.false_object, tfx(1), tfx(0), layouts.false_object, tfx(0), 0 };
    const big_tagged = @intFromPtr(&big_layout) | @intFromEnum(layouts.TypeTag.array);
    var buf: [6]Cell align(16) = .{ hdr(.tuple), big_tagged, tfx(1), tfx(2), tfx(3), 0 };

    const Redirect = struct {
        target: Cell,
        count: usize = 0,
        pub fn visitSlot(self: *@This(), _: *Cell) void {
            self.count += 1;
        }
        pub fn resolveTupleLayout(self: *@This(), _: Cell) Cell {
            return self.target;
        }
    };
    var redirect = Redirect{ .target = @intFromPtr(&small_layout) };
    const size = visitDataObjectSlots(Redirect, &redirect, @intFromPtr(&buf));
    try testing.expectEqual(@as(Cell, 32), size);
    try testing.expectEqual(@as(usize, 2), redirect.count);

    var plain = SlotOnly{};
    try testing.expectEqual(@as(Cell, 48), visitDataObjectSlots(SlotOnly, &plain, @intFromPtr(&buf)));
    try testing.expectEqual(@as(usize, 4), plain.count);
}

test "visitDataObjectSlots refreshes an alien's address after visiting its slots" {
    var ba: [4]Cell align(16) = .{ hdr(.byte_array), tfx(8), 0, 0 };
    const base_tagged = @intFromPtr(&ba) | @intFromEnum(layouts.TypeTag.byte_array);
    var buf: [6]Cell align(16) = .{ hdr(.alien), base_tagged, layouts.false_object, 3, 0, 0 };
    var rec = Recorder{};
    const size = visitDataObjectSlots(Recorder, &rec, @intFromPtr(&buf));
    try testing.expectEqual(@as(Cell, 48), size);
    try testing.expectEqualSlices(Cell, &.{ base_tagged, layouts.false_object }, rec.slots());
    const alien: *const layouts.Alien = @ptrCast(&buf);
    try testing.expectEqual(@intFromPtr(&ba) + @sizeOf(layouts.ByteArray) + 3, alien.address);

    // With no base object the address is the displacement itself.
    var raw: [6]Cell align(16) = .{ hdr(.alien), layouts.false_object, layouts.false_object, 0x1234, 0, 0 };
    _ = visitDataObjectSlots(Recorder, &rec, @intFromPtr(&raw));
    const raw_alien: *const layouts.Alien = @ptrCast(&raw);
    try testing.expectEqual(@as(Cell, 0x1234), raw_alien.address);
}

test "visitDataObjectSlots reports quotation and word entry points to fixups that want them" {
    var quot: [6]Cell align(16) = .{ hdr(.quotation), layouts.false_object, tfx(1), tfx(2), 0xABC0, 0 };
    var word: [10]Cell align(16) = .{ hdr(.word), tfx(9), layouts.false_object, layouts.false_object, layouts.false_object, layouts.false_object, layouts.false_object, layouts.false_object, layouts.false_object, 0xDEF0 };
    var rec = Recorder{};
    try testing.expectEqual(@as(Cell, 48), visitDataObjectSlots(Recorder, &rec, @intFromPtr(&quot)));
    try testing.expectEqual(@as(usize, 3), rec.count);
    try testing.expectEqual(@as(Cell, 0xABC0), rec.entry_points[0]);
    try testing.expectEqual(@as(Cell, 80), visitDataObjectSlots(Recorder, &rec, @intFromPtr(&word)));
    try testing.expectEqual(@as(usize, 11), rec.count);
    try testing.expectEqual(@as(Cell, 0xDEF0), rec.entry_points[1]);
    try testing.expectEqual(@as(usize, 2), rec.entry_count);

    // A fixup without visitEntryPoint still visits the slots.
    var plain = SlotOnly{};
    _ = visitDataObjectSlots(SlotOnly, &plain, @intFromPtr(&quot));
    _ = visitDataObjectSlots(SlotOnly, &plain, @intFromPtr(&word));
    try testing.expectEqual(@as(usize, 11), plain.count);
}

test "visitDataObjectSlots hands callstack objects to visitCallstackObject and visits wrapper and dll slots" {
    var cs: [4]Cell align(16) = .{ hdr(.callstack), tfx(16), 0, 0 };
    var wrapper: [2]Cell align(16) = .{ hdr(.wrapper), tfx(5) };
    var dll: [4]Cell align(16) = .{ hdr(.dll), tfx(6), 0, 0 };
    var rec = Recorder{};
    try testing.expectEqual(@as(Cell, 32), visitDataObjectSlots(Recorder, &rec, @intFromPtr(&cs)));
    try testing.expectEqual(@as(usize, 1), rec.callstack_visits);
    try testing.expectEqual(@as(usize, 0), rec.count);
    try testing.expectEqual(@as(Cell, 16), visitDataObjectSlots(Recorder, &rec, @intFromPtr(&wrapper)));
    try testing.expectEqual(@as(Cell, 32), visitDataObjectSlots(Recorder, &rec, @intFromPtr(&dll)));
    try testing.expectEqualSlices(Cell, &.{ tfx(5), tfx(6) }, rec.slots());

    // A fixup without visitCallstackObject just gets the size.
    var plain = SlotOnly{};
    try testing.expectEqual(@as(Cell, 32), visitDataObjectSlots(SlotOnly, &plain, @intFromPtr(&cs)));
    try testing.expectEqual(@as(usize, 0), plain.count);
}

test "objectSize matches the layouts size for each object type" {
    var arr: [4]Cell align(16) = .{ hdr(.array), tfx(2), 0, 0 };
    var ba: [4]Cell align(16) = .{ hdr(.byte_array), tfx(17), 0, 0 };
    var free: [2]Cell align(16) = .{ 1, 0 };
    try testing.expectEqual(@as(Cell, 32), objectSize(@intFromPtr(&arr)));
    try testing.expectEqual(@as(Cell, 48), objectSize(@intFromPtr(&ba)));
    try testing.expectEqual(@as(Cell, 0), objectSize(@intFromPtr(&free)));
}

test "ObjectIterator walks objects, skips free blocks and stops at a zero header" {
    var region: [16]Cell align(16) = .{0} ** 16;
    // 0: array of 2 cells (32 bytes) -> cells 0..3
    region[0] = hdr(.array);
    region[1] = tfx(2);
    // 4: free block of 32 bytes (size | free bit) -> cells 4..7
    region[4] = 32 | 1;
    // 8: byte array of 3 bytes (32 bytes) -> cells 8..11
    region[8] = hdr(.byte_array);
    region[9] = tfx(3);
    // 12: zero header terminates the walk early.
    const base = @intFromPtr(&region);
    var it = ObjectIterator.init(base, base + 16 * @sizeOf(Cell));
    try testing.expectEqual(base, it.next().?);
    try testing.expectEqual(base + 64, it.next().?);
    try testing.expectEqual(@as(?Cell, null), it.next());
    try testing.expectEqual(@as(?Cell, null), it.next());

    // A free block whose encoded size is 0 also ends the walk.
    var stuck: [2]Cell align(16) = .{ 1, 0 };
    var it2 = ObjectIterator.init(@intFromPtr(&stuck), @intFromPtr(&stuck) + 16);
    try testing.expectEqual(@as(?Cell, null), it2.next());

    // An empty range yields nothing.
    var it3 = ObjectIterator.init(base, base);
    try testing.expectEqual(@as(?Cell, null), it3.next());
}

test "CopyingDestination copies source objects once, forwards them and leaves others alone" {
    var f: gc_fixture.Fixture = undefined;
    try f.init();
    defer f.deinit();

    const heap = f.heap;
    const young = f.nurseryArray(2, tfx(5));
    const old = f.tenuredArray(1, tfx(9));
    const young_addr = layouts.UNTAG(young);

    var dest = CopyingDestination{
        .bump_here = &heap.aging.here,
        .bump_end = heap.aging.end,
        .bump_object_start = &heap.aging.object_start,
        .source_start = heap.nursery.start,
        .source_end = heap.nursery.end,
    };

    // Immediates and non-source objects pass through untouched.
    try testing.expectEqual(tfx(3), dest.copy(tfx(3)));
    try testing.expectEqual(old, dest.copy(old));

    const moved = dest.copy(young);
    const moved_addr = layouts.UNTAG(moved);
    try testing.expect(moved != young);
    try testing.expectEqual(layouts.TAG(young), layouts.TAG(moved));
    try testing.expect(moved_addr >= heap.aging.start and moved_addr < heap.aging.end);
    try testing.expectEqual(moved_addr + 32, heap.aging.here);
    const copy: *const layouts.Array = @ptrFromInt(moved_addr);
    try testing.expectEqual(@as(Cell, 2), copy.getCapacity());
    try testing.expectEqualSlices(Cell, &.{ tfx(5), tfx(5) }, copy.data()[0..2]);

    // The original now forwards to the copy, and copying again follows it.
    const original: *const layouts.Object = @ptrFromInt(young_addr);
    try testing.expect(original.isForwardingPointer());
    try testing.expectEqual(moved_addr, @intFromPtr(original.forwardingPointer()));
    try testing.expectEqual(moved, dest.copy(young));
    try testing.expectEqual(moved_addr + 32, heap.aging.here);
    try testing.expect(!dest.allocation_failed);

    // Exhausting the destination reports failure and returns the old pointer.
    const another = f.nurseryArray(1, tfx(1));
    dest.bump_end = heap.aging.here;
    try testing.expectEqual(another, dest.copy(another));
    try testing.expect(dest.allocation_failed);
    const untouched: *const layouts.Object = @ptrFromInt(layouts.UNTAG(another));
    try testing.expect(!untouched.isForwardingPointer());
}

test "CopyingDestination promotes into tenured space and queues copies on the mark stack" {
    var f: gc_fixture.Fixture = undefined;
    try f.init();
    defer f.deinit();

    const heap = f.heap;
    const young = f.nurseryArray(1, tfx(4));

    var stack: std.ArrayList(Cell) = .empty;
    defer stack.deinit(testing.allocator);

    var dest = CopyingDestination{
        .tenured_target = &heap.tenured,
        .mark_stack = &stack,
        .mark_stack_allocator = testing.allocator,
        .source_start = heap.nursery.start,
        .source_end = heap.nursery.end,
    };

    const moved = dest.copy(young);
    const moved_addr = layouts.UNTAG(moved);
    try testing.expect(heap.tenured.contains(moved_addr));
    try testing.expectEqualSlices(Cell, &.{moved_addr}, stack.items);
    const copy: *const layouts.Array = @ptrFromInt(moved_addr);
    try testing.expectEqual(tfx(4), copy.data()[0]);

    // Second source range: aging objects are copied too, nursery ones still are.
    const aging_addr = heap.allocateAging(32) orelse unreachable;
    const aging_arr: *layouts.Array = @ptrFromInt(aging_addr);
    aging_arr.header = hdr(.array);
    aging_arr.capacity = tfx(2);
    aging_arr.data()[0] = tfx(6);
    aging_arr.data()[1] = tfx(7);
    const aging_tagged = aging_addr | @intFromEnum(layouts.TypeTag.array);
    try testing.expectEqual(aging_tagged, dest.copy(aging_tagged));
    dest.source2_start = heap.aging.start;
    dest.source2_end = heap.aging.end;
    const moved2 = dest.copy(aging_tagged);
    try testing.expect(moved2 != aging_tagged);
    try testing.expect(heap.tenured.contains(layouts.UNTAG(moved2)));
    try testing.expectEqual(@as(usize, 2), stack.items.len);
}

test "CopyFixup and traceAndCopyReturnSize rewrite slots that point into the source space" {
    var f: gc_fixture.Fixture = undefined;
    try f.init();
    defer f.deinit();

    const heap = f.heap;
    const young = f.nurseryArray(1, tfx(8));
    const holder = f.tenuredArray(3, tfx(0));
    const holder_arr = gc_fixture.arrayAt(holder);
    holder_arr.data()[0] = young;
    holder_arr.data()[1] = tfx(2);
    holder_arr.data()[2] = holder;

    var dest = CopyingDestination{
        .bump_here = &heap.aging.here,
        .bump_end = heap.aging.end,
        .bump_object_start = &heap.aging.object_start,
        .source_start = heap.nursery.start,
        .source_end = heap.nursery.end,
    };

    var fixup = CopyFixup{ .destination = &dest };
    var immediate: Cell = tfx(1);
    fixup.visitSlot(&immediate);
    try testing.expectEqual(tfx(1), immediate);

    const size = traceAndCopyReturnSize(layouts.UNTAG(holder), &dest);
    try testing.expectEqual(@as(Cell, 48), size);
    try testing.expect(holder_arr.data()[0] != young);
    try testing.expect(heap.aging.start <= layouts.UNTAG(holder_arr.data()[0]));
    try testing.expectEqual(tfx(2), holder_arr.data()[1]);
    try testing.expectEqual(holder, holder_arr.data()[2]);
    const copy: *const layouts.Array = @ptrFromInt(layouts.UNTAG(holder_arr.data()[0]));
    try testing.expectEqual(tfx(8), copy.data()[0]);
}
