const std = @import("std");
const builtin = @import("builtin");
const layouts = @import("layouts.zig");
const objects = @import("objects.zig");
const segments = @import("segments.zig");
const signals = @import("signals.zig");
const Cell = layouts.Cell;
const VMError = signals.VMError;

// Stack reserved space for overflow handling
// When the callstack fills up, we chop off this many bytes to have space to work with
// macOS 64 bit needs more than 8192. See issue #1419.
pub const stack_reserved: Cell = 16384;

pub const FRAME_RETURN_ADDRESS: Cell = if (builtin.cpu.arch == .aarch64) 8 else 0;

// Number of cells subtracted from the callstack segment end to get the
// callstack bottom. Must match the C++ VM (and thus the image's compiled
// subprimitives): aarch64 uses end-16 (CALLSTACK_BOTTOM in cpu-arm.64.hpp),
// x86-64 uses end-40 (cpu-x86.64.hpp).
pub const CALLSTACK_BOTTOM_OFFSET: Cell = if (builtin.cpu.arch == .aarch64) 2 else 5;

pub const Context = extern struct {
    callstack_top: Cell,
    callstack_bottom: Cell,

    datastack: Cell,

    retainstack: Cell,

    callstack_save: Cell,

    datastack_seg: ?*segments.Segment,
    retainstack_seg: ?*segments.Segment,
    callstack_seg: ?*segments.Segment,

    context_objects: [objects.context_object_count]Cell,

    // Inactive context marker: not in active_contexts.
    active_index: u32,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, ds_size: Cell, rs_size: Cell, cs_size: Cell) !Self {
        var ctx: Self = undefined;

        ctx.callstack_save = 0;
        ctx.datastack_seg = null;
        ctx.retainstack_seg = null;
        ctx.callstack_seg = null;

        const ds_seg = try allocator.create(segments.Segment);
        ds_seg.* = try segments.Segment.init(ds_size, false);
        ctx.datastack_seg = ds_seg;

        const rs_seg = try allocator.create(segments.Segment);
        rs_seg.* = try segments.Segment.init(rs_size, false);
        ctx.retainstack_seg = rs_seg;

        const cs_seg = try allocator.create(segments.Segment);
        cs_seg.* = try segments.Segment.initWithGuardPages(cs_size, false, segments.Segment.low_guard_pages);
        ctx.callstack_seg = cs_seg;

        ctx.reset();
        ctx.active_index = std.math.maxInt(u32);

        return ctx;
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        if (self.datastack_seg) |seg| {
            var s = seg;
            s.deinit();
            allocator.destroy(s);
            self.datastack_seg = null;
        }
        if (self.retainstack_seg) |seg| {
            var s = seg;
            s.deinit();
            allocator.destroy(s);
            self.retainstack_seg = null;
        }
        if (self.callstack_seg) |seg| {
            var s = seg;
            s.deinit();
            allocator.destroy(s);
            self.callstack_seg = null;
        }
    }

    pub fn resetDatastack(self: *Self) void {
        if (self.datastack_seg) |seg| {
            self.datastack = seg.start - @sizeOf(Cell);
            fillStackSeg(self.datastack, seg, 0x11111111);
        }
    }

    pub fn resetRetainstack(self: *Self) void {
        if (self.retainstack_seg) |seg| {
            self.retainstack = seg.start - @sizeOf(Cell);
            fillStackSeg(self.retainstack, seg, 0x22222222);
        }
    }

    pub fn resetCallstack(self: *Self) void {
        if (self.callstack_seg) |seg| {
            const callstack_bottom_offset = @sizeOf(Cell) * CALLSTACK_BOTTOM_OFFSET;
            self.callstack_bottom = seg.end - callstack_bottom_offset;
            self.callstack_top = self.callstack_bottom;
        }
    }

    pub fn resetContextObjects(self: *Self) void {
        @memset(self.context_objects[0..], layouts.false_object);
    }

    pub fn reset(self: *Self) void {
        self.resetDatastack();
        self.resetRetainstack();
        self.resetCallstack();
        self.resetContextObjects();
        // Preserve callstack_save so end_callback restores the C stack pointer.
    }

    pub fn isActive(self: *const Self) bool {
        return self.active_index != std.math.maxInt(u32);
    }

    pub fn peek(self: *const Self) Cell {
        return @as(*Cell, @ptrFromInt(self.datastack)).*;
    }

    pub fn replace(self: *Self, tagged: Cell) void {
        @as(*Cell, @ptrFromInt(self.datastack)).* = tagged;
    }

    pub fn pop(self: *Self) Cell {
        const value = self.peek();
        self.datastack -= @sizeOf(Cell);
        return value;
    }

    pub fn push(self: *Self, tagged: Cell) void {
        self.datastack += @sizeOf(Cell);
        self.replace(tagged);
    }

    pub fn peekRetain(self: *const Self) Cell {
        return @as(*Cell, @ptrFromInt(self.retainstack)).*;
    }

    pub fn popRetain(self: *Self) Cell {
        const value = self.peekRetain();
        self.retainstack -= @sizeOf(Cell);
        return value;
    }

    pub fn pushRetain(self: *Self, tagged: Cell) void {
        self.retainstack += @sizeOf(Cell);
        @as(*Cell, @ptrFromInt(self.retainstack)).* = tagged;
    }

    pub fn datastackDepth(self: *const Self) Cell {
        if (self.datastack_seg) |seg| {
            return (self.datastack - (seg.start - @sizeOf(Cell))) / @sizeOf(Cell);
        }
        return 0;
    }

    pub fn retainstackDepth(self: *const Self) Cell {
        if (self.retainstack_seg) |seg| {
            return (self.retainstack - (seg.start - @sizeOf(Cell))) / @sizeOf(Cell);
        }
        return 0;
    }

    pub fn datastackInBounds(self: *const Self, ptr: *const Cell) bool {
        const seg = self.datastack_seg orelse return false;
        const addr = @intFromPtr(ptr);
        return addr >= seg.start and addr < seg.end;
    }

    pub fn retainstackInBounds(self: *const Self, ptr: *const Cell) bool {
        const seg = self.retainstack_seg orelse return false;
        const addr = @intFromPtr(ptr);
        return addr >= seg.start and addr < seg.end;
    }

    pub fn callstackInBounds(self: *const Self, ptr: *const Cell) bool {
        const seg = self.callstack_seg orelse return false;
        const addr = @intFromPtr(ptr);
        return addr >= seg.start and addr < seg.end;
    }

    pub fn fixStacks(self: *Self) void {
        if (self.datastack_seg) |seg| {
            std.debug.assert(self.datastack <= std.math.maxInt(Cell) - @sizeOf(Cell));
            std.debug.assert(self.datastack <= std.math.maxInt(Cell) - stack_reserved);
            const datastack_min = self.datastack + @sizeOf(Cell);
            const datastack_res = self.datastack + stack_reserved;

            if ((datastack_min < seg.start) or
                (datastack_res >= seg.end))
            {
                self.resetDatastack();
            }
        }

        if (self.retainstack_seg) |seg| {
            std.debug.assert(self.retainstack <= std.math.maxInt(Cell) - @sizeOf(Cell));
            std.debug.assert(self.retainstack <= std.math.maxInt(Cell) - stack_reserved);
            const retainstack_min = self.retainstack + @sizeOf(Cell);
            const retainstack_res = self.retainstack + stack_reserved;

            if ((retainstack_min < seg.start) or
                (retainstack_res >= seg.end))
            {
                self.resetRetainstack();
            }
        }
    }

    pub fn addressToError(self: *const Self, addr: Cell) VMError {
        if (self.datastack_seg) |seg| {
            if (seg.isUnderflow(addr))
                return .datastack_underflow;
            if (seg.isOverflow(addr))
                return .datastack_overflow;
        }

        if (self.retainstack_seg) |seg| {
            if (seg.isUnderflow(addr))
                return .retainstack_underflow;
            if (seg.isOverflow(addr))
                return .retainstack_overflow;
        }

        // These are flipped because the callstack grows downwards
        if (self.callstack_seg) |seg| {
            if (seg.isUnderflow(addr))
                return .callstack_overflow;
            if (seg.isOverflow(addr))
                return .callstack_underflow;
        }

        return .memory;
    }
};

// Fill unused stack memory with a pattern for debugging.
pub fn fillStackSeg(top_ptr: Cell, seg: *segments.Segment, pattern: Cell) void {
    if (comptime @import("builtin").mode == .Debug) {
        const clear_start = top_ptr + @sizeOf(Cell);
        const clear_size = seg.end - clear_start;
        if (clear_size > 0 and clear_start < seg.end) {
            const ptr: [*]Cell = @ptrFromInt(clear_start);
            const count = clear_size / @sizeOf(Cell);
            @memset(ptr[0..count], pattern);
        }
    }
}

comptime {
    std.debug.assert(@offsetOf(Context, "callstack_top") == 0 * @sizeOf(Cell));
    std.debug.assert(@offsetOf(Context, "callstack_bottom") == 1 * @sizeOf(Cell));
    std.debug.assert(@offsetOf(Context, "datastack") == 2 * @sizeOf(Cell));
    std.debug.assert(@offsetOf(Context, "retainstack") == 3 * @sizeOf(Cell));
    std.debug.assert(@offsetOf(Context, "callstack_save") == 4 * @sizeOf(Cell));
}

// --- Tests ---

test "Context.init lays out the three stacks and starts empty" {
    const allocator = std.testing.allocator;
    var ctx = try Context.init(allocator, 4096, 8192, 16384);
    defer ctx.deinit(allocator);

    const ds = ctx.datastack_seg.?;
    const rs = ctx.retainstack_seg.?;
    const cs = ctx.callstack_seg.?;

    // Sizes are page aligned and the usable ranges are consistent.
    try std.testing.expectEqual(layouts.alignCell(4096, segments.page_size), ds.size);
    try std.testing.expectEqual(layouts.alignCell(8192, segments.page_size), rs.size);
    try std.testing.expectEqual(layouts.alignCell(16384, segments.page_size), cs.size);
    try std.testing.expectEqual(ds.start + ds.size, ds.end);

    // Data and retain stacks grow upwards from one cell below the segment.
    try std.testing.expectEqual(ds.start - @sizeOf(Cell), ctx.datastack);
    try std.testing.expectEqual(rs.start - @sizeOf(Cell), ctx.retainstack);
    try std.testing.expectEqual(@as(Cell, 0), ctx.datastackDepth());
    try std.testing.expectEqual(@as(Cell, 0), ctx.retainstackDepth());

    // The callstack grows downwards from a fixed distance below the segment end.
    try std.testing.expectEqual(cs.end - @sizeOf(Cell) * CALLSTACK_BOTTOM_OFFSET, ctx.callstack_bottom);
    try std.testing.expectEqual(ctx.callstack_bottom, ctx.callstack_top);
    try std.testing.expectEqual(@as(Cell, 0), ctx.callstack_save);

    for (ctx.context_objects) |obj| try std.testing.expectEqual(layouts.false_object, obj);
    try std.testing.expectEqual(@as(usize, objects.context_object_count), ctx.context_objects.len);
    try std.testing.expect(!ctx.isActive());

    // deinit releases the segments and is idempotent.
    ctx.deinit(allocator);
    try std.testing.expect(ctx.datastack_seg == null);
    try std.testing.expect(ctx.retainstack_seg == null);
    try std.testing.expect(ctx.callstack_seg == null);
    try std.testing.expectEqual(@as(Cell, 0), ctx.datastackDepth());
}

test "Context data and retain stack operations" {
    const allocator = std.testing.allocator;
    var ctx = try Context.init(allocator, 4096, 4096, 16384);
    defer ctx.deinit(allocator);

    const base = ctx.datastack;
    ctx.push(layouts.tagFixnum(1));
    ctx.push(layouts.tagFixnum(2));
    ctx.push(layouts.tagFixnum(3));
    try std.testing.expectEqual(@as(Cell, 3), ctx.datastackDepth());
    try std.testing.expectEqual(base + 3 * @sizeOf(Cell), ctx.datastack);
    try std.testing.expectEqual(layouts.tagFixnum(3), ctx.peek());

    // replace overwrites the top without moving the pointer.
    ctx.replace(layouts.tagFixnum(30));
    try std.testing.expectEqual(@as(Cell, 3), ctx.datastackDepth());
    try std.testing.expectEqual(layouts.tagFixnum(30), ctx.pop());
    try std.testing.expectEqual(layouts.tagFixnum(2), ctx.pop());
    try std.testing.expectEqual(@as(Cell, 1), ctx.datastackDepth());

    // The retain stack is independent of the data stack.
    ctx.pushRetain(layouts.tagFixnum(10));
    ctx.pushRetain(layouts.tagFixnum(20));
    try std.testing.expectEqual(@as(Cell, 2), ctx.retainstackDepth());
    try std.testing.expectEqual(layouts.tagFixnum(20), ctx.peekRetain());
    try std.testing.expectEqual(layouts.tagFixnum(20), ctx.popRetain());
    try std.testing.expectEqual(layouts.tagFixnum(10), ctx.popRetain());
    try std.testing.expectEqual(@as(Cell, 0), ctx.retainstackDepth());
    try std.testing.expectEqual(@as(Cell, 1), ctx.datastackDepth());
    try std.testing.expectEqual(layouts.tagFixnum(1), ctx.pop());
    try std.testing.expectEqual(base, ctx.datastack);

    // The stack words live inside the segments.
    ctx.push(layouts.tagFixnum(5));
    try std.testing.expect(ctx.datastackInBounds(@ptrFromInt(ctx.datastack)));
    try std.testing.expect(!ctx.retainstackInBounds(@ptrFromInt(ctx.datastack)));
    try std.testing.expect(!ctx.callstackInBounds(@ptrFromInt(ctx.datastack)));
    ctx.pushRetain(layouts.tagFixnum(6));
    try std.testing.expect(ctx.retainstackInBounds(@ptrFromInt(ctx.retainstack)));
    try std.testing.expect(ctx.callstackInBounds(@ptrFromInt(ctx.callstack_top - @sizeOf(Cell))));
    var local: Cell = 0;
    try std.testing.expect(!ctx.datastackInBounds(&local));
    try std.testing.expect(!ctx.retainstackInBounds(&local));
    try std.testing.expect(!ctx.callstackInBounds(&local));
    // The segment end itself is outside.
    try std.testing.expect(!ctx.datastackInBounds(@ptrFromInt(ctx.datastack_seg.?.end)));
}

test "Context.reset empties every stack and clears context objects" {
    const allocator = std.testing.allocator;
    var ctx = try Context.init(allocator, 4096, 4096, 16384);
    defer ctx.deinit(allocator);

    ctx.push(layouts.tagFixnum(1));
    ctx.pushRetain(layouts.tagFixnum(2));
    ctx.callstack_top -= 64;
    ctx.callstack_save = 0xabc;
    ctx.context_objects[0] = layouts.tagFixnum(7);
    ctx.context_objects[3] = layouts.tagFixnum(9);

    ctx.reset();

    try std.testing.expectEqual(@as(Cell, 0), ctx.datastackDepth());
    try std.testing.expectEqual(@as(Cell, 0), ctx.retainstackDepth());
    try std.testing.expectEqual(ctx.callstack_bottom, ctx.callstack_top);
    // callstack_save is deliberately preserved for end_callback.
    try std.testing.expectEqual(@as(Cell, 0xabc), ctx.callstack_save);
    for (ctx.context_objects) |obj| try std.testing.expectEqual(layouts.false_object, obj);

    // The individual resets work on their own.
    ctx.push(layouts.tagFixnum(1));
    ctx.pushRetain(layouts.tagFixnum(2));
    ctx.resetDatastack();
    try std.testing.expectEqual(@as(Cell, 0), ctx.datastackDepth());
    try std.testing.expectEqual(@as(Cell, 1), ctx.retainstackDepth());
    ctx.resetRetainstack();
    try std.testing.expectEqual(@as(Cell, 0), ctx.retainstackDepth());

    // In Debug builds the unused part of a reset stack is filled with a pattern.
    if (builtin.mode == .Debug) {
        const ds = ctx.datastack_seg.?;
        const words: [*]const Cell = @ptrFromInt(ds.start);
        try std.testing.expectEqual(@as(Cell, 0x11111111), words[0]);
        try std.testing.expectEqual(@as(Cell, 0x11111111), words[ds.size / @sizeOf(Cell) - 1]);
        const rs = ctx.retainstack_seg.?;
        const rwords: [*]const Cell = @ptrFromInt(rs.start);
        try std.testing.expectEqual(@as(Cell, 0x22222222), rwords[0]);
    }
}

test "fillStackSeg fills from one cell above the top to the segment end" {
    if (builtin.mode != .Debug) return error.SkipZigTest;
    var seg = try segments.Segment.init(4096, false);
    defer seg.deinit();
    const words: [*]Cell = @ptrFromInt(seg.start);
    const count = seg.size / @sizeOf(Cell);
    @memset(words[0..count], 0);

    // Top is the third cell: cells 0..2 are live and must be left alone.
    fillStackSeg(seg.start + 2 * @sizeOf(Cell), &seg, 0xdead);
    try std.testing.expectEqual(@as(Cell, 0), words[0]);
    try std.testing.expectEqual(@as(Cell, 0), words[2]);
    try std.testing.expectEqual(@as(Cell, 0xdead), words[3]);
    try std.testing.expectEqual(@as(Cell, 0xdead), words[count - 1]);

    // A top at the very end fills nothing.
    @memset(words[0..count], 0);
    fillStackSeg(seg.end - @sizeOf(Cell), &seg, 0xdead);
    try std.testing.expectEqual(@as(Cell, 0), words[count - 1]);
}

test "Context.fixStacks resets a stack pointer that left its segment" {
    const allocator = std.testing.allocator;
    // The stacks must be larger than stack_reserved for a healthy pointer to
    // have enough headroom.
    var ctx = try Context.init(allocator, 4 * stack_reserved, 4 * stack_reserved, 16384);
    defer ctx.deinit(allocator);

    const ds = ctx.datastack_seg.?;
    const rs = ctx.retainstack_seg.?;

    // A healthy stack is untouched.
    ctx.push(layouts.tagFixnum(1));
    ctx.pushRetain(layouts.tagFixnum(2));
    const ds_before = ctx.datastack;
    const rs_before = ctx.retainstack;
    ctx.fixStacks();
    try std.testing.expectEqual(ds_before, ctx.datastack);
    try std.testing.expectEqual(rs_before, ctx.retainstack);

    // Underflow: the pointer dropped below the segment start.
    ctx.datastack = ds.start - 2 * @sizeOf(Cell);
    ctx.fixStacks();
    try std.testing.expectEqual(ds.start - @sizeOf(Cell), ctx.datastack);
    try std.testing.expectEqual(rs_before, ctx.retainstack);

    // Overflow: less than stack_reserved bytes left before the segment end.
    ctx.retainstack = rs.end - stack_reserved + @sizeOf(Cell);
    ctx.fixStacks();
    try std.testing.expectEqual(rs.start - @sizeOf(Cell), ctx.retainstack);

    // Exactly stack_reserved bytes of headroom is still fine.
    ctx.datastack = ds.end - stack_reserved - @sizeOf(Cell);
    ctx.fixStacks();
    try std.testing.expectEqual(ds.end - stack_reserved - @sizeOf(Cell), ctx.datastack);
}

test "Context.addressToError classifies guard page faults per stack" {
    const allocator = std.testing.allocator;
    var ctx = try Context.init(allocator, 4096, 4096, 16384);
    defer ctx.deinit(allocator);

    const ds = ctx.datastack_seg.?;
    const rs = ctx.retainstack_seg.?;
    const cs = ctx.callstack_seg.?;

    try std.testing.expectEqual(VMError.datastack_underflow, ctx.addressToError(ds.start - 1));
    try std.testing.expectEqual(VMError.datastack_underflow, ctx.addressToError(ds.alloc_base));
    try std.testing.expectEqual(VMError.datastack_overflow, ctx.addressToError(ds.end));
    try std.testing.expectEqual(VMError.datastack_overflow, ctx.addressToError(ds.end + segments.page_size - 1));

    try std.testing.expectEqual(VMError.retainstack_underflow, ctx.addressToError(rs.start - 1));
    try std.testing.expectEqual(VMError.retainstack_overflow, ctx.addressToError(rs.end));

    // The callstack grows downwards, so running off its start is an overflow.
    try std.testing.expectEqual(VMError.callstack_overflow, ctx.addressToError(cs.start - 1));
    try std.testing.expectEqual(VMError.callstack_overflow, ctx.addressToError(cs.alloc_base));
    try std.testing.expectEqual(VMError.callstack_underflow, ctx.addressToError(cs.end));

    // Addresses inside a stack or elsewhere are plain memory errors.
    try std.testing.expectEqual(VMError.memory, ctx.addressToError(ds.start));
    try std.testing.expectEqual(VMError.memory, ctx.addressToError(ctx.callstack_top - @sizeOf(Cell)));
    try std.testing.expectEqual(VMError.memory, ctx.addressToError(0x10));
    try std.testing.expectEqual(VMError.memory, ctx.addressToError(ds.end + segments.page_size));

    // Without segments nothing can be classified.
    var bare: Context = undefined;
    bare.datastack_seg = null;
    bare.retainstack_seg = null;
    bare.callstack_seg = null;
    try std.testing.expectEqual(VMError.memory, bare.addressToError(ds.start - 1));
    try std.testing.expect(!bare.datastackInBounds(@ptrFromInt(ds.start)));
    try std.testing.expectEqual(@as(Cell, 0), bare.datastackDepth());
    try std.testing.expectEqual(@as(Cell, 0), bare.retainstackDepth());
}

test "FactorVM.newContext and deleteContext track active and unused contexts" {
    const vm_mod = @import("vm.zig");
    const allocator = std.testing.allocator;

    const vm = try vm_mod.FactorVM.init(allocator);
    vm.vm_asm.ctx = try vm.newContext();
    vm.vm_asm.spare_ctx = try vm.newContext();
    defer vm.deinit();

    const main_ctx = vm.vm_asm.ctx;
    const spare = vm.vm_asm.spare_ctx;
    try std.testing.expect(main_ctx.isActive());
    try std.testing.expectEqual(@as(u32, 0), main_ctx.active_index);
    try std.testing.expectEqual(@as(u32, 1), spare.active_index);
    try std.testing.expectEqual(@as(usize, 2), vm.active_contexts.items.len);
    try std.testing.expectEqual(@as(usize, 0), vm.unused_contexts.items.len);

    // New contexts become active at the end of the list.
    const third = try vm.newContext();
    const fourth = try vm.newContext();
    try std.testing.expectEqual(@as(u32, 2), third.active_index);
    try std.testing.expectEqual(@as(u32, 3), fourth.active_index);
    try std.testing.expectEqual(fourth, vm.active_contexts.items[3]);
    fourth.push(layouts.tagFixnum(42));
    fourth.context_objects[1] = layouts.tagFixnum(1);

    // Deleting the current context (third, in the middle) swaps the last
    // active context into its slot and parks it on the unused list.
    vm.vm_asm.ctx = third;
    vm.deleteContext();
    vm.vm_asm.ctx = main_ctx;
    try std.testing.expect(!third.isActive());
    try std.testing.expectEqual(@as(usize, 3), vm.active_contexts.items.len);
    try std.testing.expectEqual(fourth, vm.active_contexts.items[2]);
    try std.testing.expectEqual(@as(u32, 2), fourth.active_index);
    try std.testing.expectEqual(@as(usize, 1), vm.unused_contexts.items.len);
    try std.testing.expectEqual(third, vm.unused_contexts.items[0]);

    // Deleting fourth as well, then asking for a context, recycles the most
    // recently parked one, reset.
    vm.vm_asm.ctx = fourth;
    vm.deleteContext();
    vm.vm_asm.ctx = main_ctx;
    try std.testing.expectEqual(@as(usize, 2), vm.unused_contexts.items.len);
    try std.testing.expectEqual(@as(usize, 2), vm.active_contexts.items.len);
    const recycled = try vm.newContext();
    try std.testing.expectEqual(fourth, recycled);
    try std.testing.expect(recycled.isActive());
    try std.testing.expectEqual(@as(u32, 2), recycled.active_index);
    try std.testing.expectEqual(@as(Cell, 0), recycled.datastackDepth());
    try std.testing.expectEqual(layouts.false_object, recycled.context_objects[1]);
    try std.testing.expectEqual(@as(usize, 1), vm.unused_contexts.items.len);

    // Parking more than 10 contexts frees the oldest ones. Allocate them all
    // first so that none is recycled from the unused list.
    var extra: [12]*Context = undefined;
    for (&extra) |*slot| slot.* = try vm.newContext();
    try std.testing.expectEqual(third, extra[0]);
    try std.testing.expectEqual(@as(usize, 15), vm.active_contexts.items.len);
    try std.testing.expectEqual(@as(usize, 0), vm.unused_contexts.items.len);
    vm.vm_asm.ctx = recycled;
    vm.deleteContext();
    for (extra) |c| {
        vm.vm_asm.ctx = c;
        vm.deleteContext();
    }
    vm.vm_asm.ctx = main_ctx;
    try std.testing.expectEqual(@as(usize, 10), vm.unused_contexts.items.len);
    try std.testing.expectEqual(@as(usize, 2), vm.active_contexts.items.len);
    // The survivors are the most recently parked ones.
    try std.testing.expectEqual(extra[11], vm.unused_contexts.items[9]);
    try std.testing.expectEqual(extra[2], vm.unused_contexts.items[0]);

    // clearActiveContexts deactivates every context at once.
    vm.clearActiveContexts();
    try std.testing.expect(!main_ctx.isActive());
    try std.testing.expect(!spare.isActive());
    try std.testing.expectEqual(@as(usize, 0), vm.active_contexts.items.len);
}

test "FactorVM.initContext stores an alien to the context in slot 2" {
    const vm_mod = @import("vm.zig");
    const data_heap_mod = @import("data_heap.zig");
    const allocator = std.testing.allocator;

    const vm = try vm_mod.FactorVM.init(allocator);
    vm.vm_asm.ctx = try vm.newContext();
    vm.vm_asm.spare_ctx = try vm.newContext();
    defer {
        vm.cards_array = null;
        vm.decks_array = null;
        vm.deinit();
    }
    const heap = try data_heap_mod.DataHeap.init(allocator, 64 * 1024, 16 * 1024, 16 * 1024);
    defer heap.deinit();
    vm.setDataHeap(heap);

    const ctx = vm.vm_asm.ctx;
    vm.initContext(ctx);
    const alien_cell = ctx.context_objects[2];
    try std.testing.expect(layouts.hasTag(alien_cell, .alien));
    const alien: *const layouts.Alien = @ptrFromInt(layouts.UNTAG(alien_cell));
    try std.testing.expectEqual(layouts.false_object, alien.base);
    try std.testing.expectEqual(@intFromPtr(ctx), alien.address);
    try std.testing.expectEqual(ctx, vm.getContextFromAlien(alien_cell).?);
    try std.testing.expect(vm.getContextFromAlien(layouts.false_object) == null);
}
