const std = @import("std");
const builtin = @import("builtin");

const code_blocks = @import("code_blocks.zig");
const contexts = @import("contexts.zig");
const growable = @import("growable.zig");
const layouts = @import("layouts.zig");
const vm_mod = @import("vm.zig");

const Cell = layouts.Cell;
const CodeBlock = code_blocks.CodeBlock;
const FactorVM = vm_mod.FactorVM;
const VMAssemblyFields = vm_mod.VMAssemblyFields;

const FRAME_RETURN_ADDRESS = contexts.FRAME_RETURN_ADDRESS;

/// Iterate a callstack *object's* frames. `cs_cell` must be a GC root the
/// caller keeps live (e.g. pushed on data_roots): `iterator.call` may allocate
/// and trigger a GC that moves the callstack object, so the callstack base is
/// re-derived from `cs_cell` every iteration rather than captured once.
pub fn iterateCallstackObject(vm: *FactorVM, cs_cell: *Cell, comptime Iterator: type, iterator: *Iterator) void {
    const code = vm.code orelse return;
    // Length is an immutable fixnum, so reading it once (as a number) is safe
    // even though the object may move.
    const frame_length = layouts.untagFixnum(@as(*const layouts.Callstack, @ptrFromInt(layouts.UNTAG(cs_cell.*))).length);
    var frame_offset: Cell = 0;

    if (builtin.cpu.arch == .aarch64) {
        while (frame_offset < frame_length) {
            const callstack: *const layouts.Callstack = @ptrFromInt(layouts.UNTAG(cs_cell.*));
            const frame_top = callstack.frameTopAt(frame_offset);
            const frame_size = @as(*const Cell, @ptrFromInt(frame_top)).*;

            if (frame_size == 0 or frame_offset + frame_size > frame_length) break;

            const ret_addr = @as(*const Cell, @ptrFromInt(frame_top + FRAME_RETURN_ADDRESS)).*;
            const block = code.codeBlockForAddress(ret_addr) orelse break;

            iterator.call(frame_top, frame_size, block, ret_addr);

            frame_offset += frame_size;
        }
    } else {
        while (frame_offset < frame_length) {
            const callstack: *const layouts.Callstack = @ptrFromInt(layouts.UNTAG(cs_cell.*));
            const frame_top = callstack.frameTopAt(frame_offset);
            const ret_addr = @as(*const Cell, @ptrFromInt(frame_top + FRAME_RETURN_ADDRESS)).*;

            const block = code.codeBlockForAddress(ret_addr) orelse break;
            const frame_size = block.stackFrameSizeForAddress(ret_addr);

            iterator.call(frame_top + FRAME_RETURN_ADDRESS, frame_size - FRAME_RETURN_ADDRESS, block, ret_addr);

            frame_offset += frame_size;
        }
    }
}

pub fn iterateCallstack(vm: *FactorVM, ctx: *const contexts.Context, comptime Iterator: type, iterator: *Iterator) void {
    var top = ctx.callstack_top;
    const bottom = ctx.callstack_bottom;

    const code = vm.code orelse return;

    if (builtin.cpu.arch == .aarch64) {
        while (top < bottom) {
            const ret_addr = @as(*const Cell, @ptrFromInt(top + FRAME_RETURN_ADDRESS)).*;
            if (ret_addr == 0) break;

            const block = code.codeBlockForAddress(ret_addr) orelse break;

            const next_frame = @as(*const Cell, @ptrFromInt(top)).*;
            const frame_size = next_frame -| top;

            iterator.call(top, frame_size, block, ret_addr);

            top = next_frame;
        }
    } else {
        while (top < bottom) {
            const ret_addr = @as(*const Cell, @ptrFromInt(top + FRAME_RETURN_ADDRESS)).*;
            if (ret_addr == 0) break;

            const block = code.codeBlockForAddress(ret_addr) orelse break;
            const frame_size = block.stackFrameSizeForAddress(ret_addr);

            iterator.call(top + FRAME_RETURN_ADDRESS, frame_size - FRAME_RETURN_ADDRESS, block, ret_addr);

            top += frame_size;
        }
    }
}

pub export fn primitive_callstack_to_array(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();

    var cs_cell = vm.peek();
    vm.checkTag(cs_cell, .callstack);

    // Root the callstack object: block.scan() below can JIT-compile a quotation
    // and trigger a GC that moves it, and the frame walk dereferences it every
    // iteration (matches C++ data_root<callstack>).
    std.debug.assert(vm.data_roots.items.len < vm.data_roots.capacity);
    vm.data_roots.appendAssumeCapacity(&cs_cell);
    defer _ = vm.data_roots.pop();

    // Accumulate into a rooted, growable Factor array. The old fixed 256-cell
    // Zig buffer silently truncated callstacks past ~85 frames and held tagged
    // pointers that a GC inside scan() could invalidate before they were copied
    // into the result (matches C++ growable_array frames).
    var frames = growable.GrowableArray.init(vm, 8) orelse vm.memoryError();
    std.debug.assert(vm.data_roots.items.len < vm.data_roots.capacity);
    vm.data_roots.appendAssumeCapacity(&frames.elements);
    defer _ = vm.data_roots.pop();

    const FrameAccumulator = struct {
        frames: *growable.GrowableArray,
        vm_ref: *FactorVM,

        pub fn call(self: *@This(), _: Cell, _: Cell, block: *const CodeBlock, addr: Cell) void {
            var owner = block.owner;
            var owner_quot = if (block.blockType() != .optimized and
                layouts.hasTag(owner, .word))
            blk: {
                const word: *const layouts.Word = @ptrFromInt(layouts.UNTAG(owner));
                break :blk word.def;
            } else owner;

            // scan() may GC (it can JIT-compile the frame's quotation), so root
            // owner and owner_quot across it before reading scan (C++ wraps each
            // in a data_root). scan itself is a fixnum (immediate).
            const vm_ref = self.vm_ref;
            std.debug.assert(vm_ref.data_roots.items.len + 2 <= vm_ref.data_roots.capacity);
            vm_ref.data_roots.appendAssumeCapacity(&owner);
            vm_ref.data_roots.appendAssumeCapacity(&owner_quot);
            defer {
                _ = vm_ref.data_roots.pop();
                _ = vm_ref.data_roots.pop();
            }

            const scan = block.scan(vm_ref, addr);

            // add() may GC; owner/owner_quot stay rooted above, scan is immediate.
            if (!self.frames.add(owner)) vm_ref.memoryError();
            if (!self.frames.add(owner_quot)) vm_ref.memoryError();
            if (!self.frames.add(scan)) vm_ref.memoryError();
        }
    };

    var accumulator = FrameAccumulator{ .frames = &frames, .vm_ref = vm };
    iterateCallstackObject(vm, &cs_cell, FrameAccumulator, &accumulator);

    if (!frames.trim()) vm.memoryError();
    vm.replace(frames.toArray());
}

pub export fn primitive_callstack_bounds(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    const ctx = vm.vm_asm.ctx;
    if (ctx.callstack_seg) |seg| {
        var start_alien = vm.allotAlien(layouts.false_object, seg.start);
        vm.data_roots.appendAssumeCapacity(&start_alien);
        defer _ = vm.data_roots.pop();
        const end_alien = vm.allotAlien(layouts.false_object, seg.end);
        vm.push(start_alien);
        vm.push(end_alien);
        return;
    }
    vm.push(layouts.false_object);
    vm.push(layouts.false_object);
}

// --- Tests ---

const testing = std.testing;
const segments = @import("segments.zig");
const free_list_mod = @import("free_list.zig");
const code_heap_mod = @import("code_heap.zig");
const write_barrier = @import("write_barrier.zig");
const data_heap_mod = @import("data_heap.zig");

// A code heap backed by a small non-executable segment, enough for the
// address lookups the callstack walkers do.
const CodeEnv = struct {
    seg: segments.Segment,
    fl: *free_list_mod.FreeListAllocator,
    heap: *code_heap_mod.CodeHeap,

    fn init(allocator: std.mem.Allocator) !CodeEnv {
        var seg = try segments.Segment.init(64 * 1024, false);
        errdefer seg.deinit();
        const fl = try allocator.create(free_list_mod.FreeListAllocator);
        errdefer allocator.destroy(fl);
        fl.* = free_list_mod.FreeListAllocator.init(allocator, seg.start, seg.size);
        const heap = try allocator.create(code_heap_mod.CodeHeap);
        heap.* = .{
            .seg = null,
            .free_list = fl,
            .safepoint_page = 0,
            .code_start = seg.start,
            .code_size = seg.size,
            .allocator = allocator,
            .remembered_sets = write_barrier.CodeHeapRememberedSets.init(allocator),
        };
        return .{ .seg = seg, .fl = fl, .heap = heap };
    }

    fn deinit(self: *CodeEnv, allocator: std.mem.Allocator) void {
        self.heap.deinit();
        allocator.destroy(self.heap);
        self.fl.deinit();
        allocator.destroy(self.fl);
        self.seg.deinit();
    }

    // An optimized block of `size` bytes (a multiple of 16) with the given
    // natural stack frame size.
    fn block(self: *CodeEnv, size: Cell, frame_size: Cell) *CodeBlock {
        const b = self.heap.allocate(size).?;
        b.initialize(.optimized, size, frame_size);
        self.heap.flushPending();
        return b;
    }
};

const Frame = struct { top: Cell, size: Cell, block: *const CodeBlock, ret: Cell };

const Collector = struct {
    frames: [8]Frame = undefined,
    count: usize = 0,

    pub fn call(self: *Collector, top: Cell, size: Cell, block: *const CodeBlock, ret: Cell) void {
        self.frames[self.count] = .{ .top = top, .size = size, .block = block, .ret = ret };
        self.count += 1;
    }
};

fn writeCell(addr: Cell, value: Cell) void {
    @as(*Cell, @ptrFromInt(addr)).* = value;
}

test "iterateCallstack walks x86-64 frames using each block's frame size" {
    if (builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    const allocator = testing.allocator;
    const vm = try FactorVM.init(allocator);
    vm.vm_asm.ctx = try vm.newContext();
    vm.vm_asm.spare_ctx = try vm.newContext();
    defer vm.deinit();
    var env = try CodeEnv.init(allocator);
    defer env.deinit(allocator);

    const a = env.block(64, 32);
    const b = env.block(64, 48);
    const ret_a = a.entryPoint() + 8;
    const ret_b = b.entryPoint() + 4;
    const ctx = vm.vm_asm.ctx;

    // Without a code heap nothing is visited.
    var none = Collector{};
    ctx.callstack_top = ctx.callstack_bottom - 80;
    writeCell(ctx.callstack_top, ret_a);
    iterateCallstack(vm, ctx, Collector, &none);
    try testing.expectEqual(@as(usize, 0), none.count);

    vm.code = env.heap;

    // Two frames: a's (32 bytes) on top of b's (48 bytes), ending at bottom.
    writeCell(ctx.callstack_top + 32, ret_b);
    var c = Collector{};
    iterateCallstack(vm, ctx, Collector, &c);
    try testing.expectEqual(@as(usize, 2), c.count);
    try testing.expectEqual(ctx.callstack_top, c.frames[0].top);
    try testing.expectEqual(@as(Cell, 32), c.frames[0].size);
    try testing.expectEqual(a, c.frames[0].block);
    try testing.expectEqual(ret_a, c.frames[0].ret);
    try testing.expectEqual(ctx.callstack_top + 32, c.frames[1].top);
    try testing.expectEqual(@as(Cell, 48), c.frames[1].size);
    try testing.expectEqual(b, c.frames[1].block);
    try testing.expectEqual(ret_b, c.frames[1].ret);

    // A return address equal to the entry point means a leaf-sized frame.
    ctx.callstack_top = ctx.callstack_bottom - 64;
    writeCell(ctx.callstack_top, a.entryPoint());
    writeCell(ctx.callstack_top + CodeBlock.LEAF_FRAME_SIZE, ret_b);
    c = Collector{};
    iterateCallstack(vm, ctx, Collector, &c);
    try testing.expectEqual(@as(usize, 2), c.count);
    try testing.expectEqual(CodeBlock.LEAF_FRAME_SIZE, c.frames[0].size);
    try testing.expectEqual(@as(Cell, 48), c.frames[1].size);

    // A zero return address, or one outside the code heap, ends the walk.
    ctx.callstack_top = ctx.callstack_bottom - 80;
    writeCell(ctx.callstack_top, ret_a);
    writeCell(ctx.callstack_top + 32, 0);
    c = Collector{};
    iterateCallstack(vm, ctx, Collector, &c);
    try testing.expectEqual(@as(usize, 1), c.count);
    writeCell(ctx.callstack_top + 32, env.seg.end + 0x1000);
    c = Collector{};
    iterateCallstack(vm, ctx, Collector, &c);
    try testing.expectEqual(@as(usize, 1), c.count);

    // An empty callstack visits nothing.
    ctx.callstack_top = ctx.callstack_bottom;
    c = Collector{};
    iterateCallstack(vm, ctx, Collector, &c);
    try testing.expectEqual(@as(usize, 0), c.count);
    vm.code = null;
}

test "iterateCallstack walks aarch64 frames through the saved frame pointers" {
    if (builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    const allocator = testing.allocator;
    const vm = try FactorVM.init(allocator);
    vm.vm_asm.ctx = try vm.newContext();
    vm.vm_asm.spare_ctx = try vm.newContext();
    defer vm.deinit();
    var env = try CodeEnv.init(allocator);
    defer env.deinit(allocator);
    vm.code = env.heap;
    defer vm.code = null;

    const a = env.block(64, 32);
    const b = env.block(64, 48);
    const ret_a = a.entryPoint() + 8;
    const ret_b = b.entryPoint() + 4;
    const ctx = vm.vm_asm.ctx;

    // Each frame holds the caller's frame pointer at +0 and the return
    // address at +8; the last frame links to callstack_bottom.
    ctx.callstack_top = ctx.callstack_bottom - 80;
    const frame_b = ctx.callstack_top + 32;
    writeCell(ctx.callstack_top, frame_b);
    writeCell(ctx.callstack_top + FRAME_RETURN_ADDRESS, ret_a);
    writeCell(frame_b, ctx.callstack_bottom);
    writeCell(frame_b + FRAME_RETURN_ADDRESS, ret_b);

    var c = Collector{};
    iterateCallstack(vm, ctx, Collector, &c);
    try testing.expectEqual(@as(usize, 2), c.count);
    try testing.expectEqual(ctx.callstack_top, c.frames[0].top);
    try testing.expectEqual(@as(Cell, 32), c.frames[0].size);
    try testing.expectEqual(a, c.frames[0].block);
    try testing.expectEqual(ret_a, c.frames[0].ret);
    try testing.expectEqual(frame_b, c.frames[1].top);
    try testing.expectEqual(@as(Cell, 48), c.frames[1].size);
    try testing.expectEqual(b, c.frames[1].block);
}

test "iterateCallstackObject walks the frames stored in a callstack object" {
    if (builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    const allocator = testing.allocator;
    const vm = try FactorVM.init(allocator);
    vm.vm_asm.ctx = try vm.newContext();
    vm.vm_asm.spare_ctx = try vm.newContext();
    defer vm.deinit();
    var env = try CodeEnv.init(allocator);
    defer env.deinit(allocator);
    vm.code = env.heap;
    defer vm.code = null;

    const a = env.block(64, 32);
    const b = env.block(64, 48);
    const ret_a = a.entryPoint() + 8;
    const ret_b = b.entryPoint() + 4;

    // header, length, then 80 bytes of frames (10 cells).
    var buf: [12]Cell align(16) = .{0} ** 12;
    const stack: *layouts.Callstack = @ptrCast(&buf);
    stack.header = @as(Cell, @intFromEnum(layouts.TypeTag.callstack)) << 2;
    stack.length = layouts.tagFixnum(80);
    buf[2] = ret_a;
    buf[2 + 4] = ret_b;
    var cs_cell: Cell = @intFromPtr(&buf) | @intFromEnum(layouts.TypeTag.callstack);

    var c = Collector{};
    iterateCallstackObject(vm, &cs_cell, Collector, &c);
    try testing.expectEqual(@as(usize, 2), c.count);
    try testing.expectEqual(stack.top(), c.frames[0].top);
    try testing.expectEqual(@as(Cell, 32), c.frames[0].size);
    try testing.expectEqual(a, c.frames[0].block);
    try testing.expectEqual(ret_a, c.frames[0].ret);
    try testing.expectEqual(stack.top() + 32, c.frames[1].top);
    try testing.expectEqual(@as(Cell, 48), c.frames[1].size);
    try testing.expectEqual(b, c.frames[1].block);
    try testing.expectEqual(ret_b, c.frames[1].ret);

    // The length bounds the walk: with only the first frame's bytes the
    // second frame is never visited.
    stack.length = layouts.tagFixnum(32);
    c = Collector{};
    iterateCallstackObject(vm, &cs_cell, Collector, &c);
    try testing.expectEqual(@as(usize, 1), c.count);

    // A return address outside the heap stops the walk early.
    stack.length = layouts.tagFixnum(80);
    buf[2 + 4] = 0;
    c = Collector{};
    iterateCallstackObject(vm, &cs_cell, Collector, &c);
    try testing.expectEqual(@as(usize, 1), c.count);

    // Zero length: nothing.
    stack.length = layouts.tagFixnum(0);
    c = Collector{};
    iterateCallstackObject(vm, &cs_cell, Collector, &c);
    try testing.expectEqual(@as(usize, 0), c.count);
}

test "primitive_callstack_bounds pushes aliens for the callstack segment" {
    const allocator = testing.allocator;
    const vm = try FactorVM.init(allocator);
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

    primitive_callstack_bounds(&vm.vm_asm);
    const end_cell = vm.pop();
    const start_cell = vm.pop();
    try testing.expect(layouts.hasTag(start_cell, .alien));
    try testing.expect(layouts.hasTag(end_cell, .alien));
    const start_alien: *const layouts.Alien = @ptrFromInt(layouts.UNTAG(start_cell));
    const end_alien: *const layouts.Alien = @ptrFromInt(layouts.UNTAG(end_cell));
    const seg = vm.vm_asm.ctx.callstack_seg.?;
    try testing.expectEqual(seg.start, start_alien.address);
    try testing.expectEqual(seg.end, end_alien.address);
    try testing.expectEqual(layouts.false_object, start_alien.base);
    try testing.expectEqual(@as(Cell, 0), vm.vm_asm.ctx.datastackDepth());
}

test "primitive_callstack_to_array lists owner, quotation and scan per frame" {
    if (builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    const allocator = testing.allocator;
    const vm = try FactorVM.init(allocator);
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
    var env = try CodeEnv.init(allocator);
    defer env.deinit(allocator);
    vm.code = env.heap;
    defer vm.code = null;

    // Optimized blocks have no scan position (-1) and their owner doubles as
    // the quotation.
    const a = env.block(64, 32);
    const b = env.block(64, 48);
    a.owner = layouts.tagFixnum(77);
    b.owner = layouts.tagFixnum(88);

    var buf: [12]Cell align(16) = .{0} ** 12;
    const stack: *layouts.Callstack = @ptrCast(&buf);
    stack.header = @as(Cell, @intFromEnum(layouts.TypeTag.callstack)) << 2;
    stack.length = layouts.tagFixnum(80);
    buf[2] = a.entryPoint() + 8;
    buf[2 + 4] = b.entryPoint() + 4;

    vm.push(@intFromPtr(&buf) | @intFromEnum(layouts.TypeTag.callstack));
    primitive_callstack_to_array(&vm.vm_asm);
    const result = vm.pop();
    try testing.expect(layouts.hasTag(result, .array));
    try testing.expectEqual(@as(Cell, 6), layouts.arrayCapacity(result));
    try testing.expectEqual(layouts.tagFixnum(77), layouts.arrayNth(result, 0));
    try testing.expectEqual(layouts.tagFixnum(77), layouts.arrayNth(result, 1));
    try testing.expectEqual(layouts.tagFixnum(-1), layouts.arrayNth(result, 2));
    try testing.expectEqual(layouts.tagFixnum(88), layouts.arrayNth(result, 3));
    try testing.expectEqual(layouts.tagFixnum(88), layouts.arrayNth(result, 4));
    try testing.expectEqual(layouts.tagFixnum(-1), layouts.arrayNth(result, 5));
    try testing.expectEqual(@as(Cell, 0), vm.vm_asm.ctx.datastackDepth());
    try testing.expectEqual(@as(usize, 0), vm.data_roots.items.len);

    // An empty callstack gives an empty array.
    stack.length = layouts.tagFixnum(0);
    vm.push(@intFromPtr(&buf) | @intFromEnum(layouts.TypeTag.callstack));
    primitive_callstack_to_array(&vm.vm_asm);
    try testing.expectEqual(@as(Cell, 0), layouts.arrayCapacity(vm.pop()));
}
