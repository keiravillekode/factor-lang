// mark.zig - Full mark phase for Factor VM garbage collector
// Mark+copy nursery/aging referents into tenured, mark live tenured/code.
// (A former mark-only "simple mark" path lived here but was never wired from
// gc.zig and diverged on callstack spill promotion — removed.)

const std = @import("std");

const code_blocks = @import("code_blocks.zig");
const contexts = @import("contexts.zig");
const data_heap_mod = @import("data_heap.zig");
const free_list = @import("free_list.zig");
const gc_mod = @import("gc.zig");
const layouts = @import("layouts.zig");
const segments = @import("segments.zig");
const slot_visitor = @import("slot_visitor.zig");

const Cell = layouts.Cell;
const Context = contexts.Context;
const GC = gc_mod.GarbageCollector;

pub const FullMarkContext = struct {
    gc: *GC,
    destination: *slot_visitor.CopyingDestination,
    tenured: *data_heap_mod.TenuredSpace,
};

fn markCodeBlockIfNeeded(gc: *GC, block: *code_blocks.CodeBlock) void {
    const code = gc.vm.code orelse return;
    const marks = code.marks orelse return;
    if (block.isFree()) return;

    const addr: Cell = @intFromPtr(block);
    const size = block.size();
    if (marks.tryMarkStart(addr, size)) {
        markStackPush(gc, addr | 1);
    }
}

/// Safe push — for root scanning where total push count is hard to bound.
fn markStackPush(gc: *GC, value: Cell) void {
    gc.mark_stack.append(gc.allocator, value) catch @panic("Mark stack overflow");
}

/// Fast push — for drain loop where markStackEnsure was called first.
fn markStackPushFast(gc: *GC, value: Cell) void {
    gc.mark_stack.appendAssumeCapacity(value);
}

/// Ensure the mark stack has room for at least `n` more pushes.
/// Called before scanning an object's slots in the drain loop.
fn markStackEnsure(gc: *GC, n: Cell) void {
    gc.mark_stack.ensureUnusedCapacity(gc.allocator, n) catch @panic("Mark stack overflow");
}

// Mark a value during full GC. Comptime `assume_capacity` selects fast push
// (drain loop, where markStackEnsure was called) vs safe push (root scanning).
// Computes object size and sets full mark range at encounter time (matching
fn fullMarkValueImpl(comptime assume_capacity: bool, ctx: *FullMarkContext, value: Cell) Cell {
    if (layouts.isImmediate(value)) return value;
    const untagged = layouts.UNTAG(value);
    if (untagged < 0x1000) return value;

    if (ctx.tenured.contains(untagged)) {
        if (!ctx.tenured.marks.isMarkedUnchecked(untagged)) {
            const size = free_list.objectSizeFromHeader(untagged);
            if (ctx.tenured.marks.tryMarkStartUnchecked(untagged, size)) {
                if (assume_capacity) markStackPushFast(ctx.gc, untagged) else markStackPush(ctx.gc, untagged);
            }
        }
        return value;
    }

    // Slow path: nursery/aging copy
    const new_value = ctx.destination.copy(value);
    const new_addr = layouts.UNTAG(new_value);
    if (ctx.tenured.contains(new_addr)) {
        const size = free_list.objectSizeFromHeader(new_addr);
        if (ctx.tenured.marks.tryMarkStartUnchecked(new_addr, size)) {
            if (assume_capacity) markStackPushFast(ctx.gc, new_addr) else markStackPush(ctx.gc, new_addr);
        }
    }
    return new_value;
}

// Safe versions (root scanning — no capacity guarantee)
fn fullMarkValue(ctx: *FullMarkContext, value: Cell) Cell {
    return fullMarkValueImpl(false, ctx, value);
}

fn fullMarkSlot(slot: *Cell, ctx_ptr: *anyopaque) void {
    const ctx: *FullMarkContext = @ptrCast(@alignCast(ctx_ptr));
    slot.* = fullMarkValue(ctx, slot.*);
}

// Fast versions (drain loop — markStackEnsure was called)
fn fullMarkValueFast(ctx: *FullMarkContext, value: Cell) Cell {
    return fullMarkValueImpl(true, ctx, value);
}

fn fullMarkSlotInlineFast(slot: *Cell, ctx: *FullMarkContext) void {
    slot.* = fullMarkValueFast(ctx, slot.*);
}

pub fn fullMarkAllRoots(gc: *GC, ctx: *FullMarkContext) void {
    // Special objects
    for (&gc.vm.vm_asm.special_objects) |*slot| {
        fullMarkSlot(slot, @ptrCast(ctx));
    }

    // Contexts and stacks
    fullMarkContexts(gc, ctx);

    // Data roots
    for (gc.vm.data_roots.items) |root_ptr| {
        fullMarkSlot(root_ptr, @ptrCast(ctx));
    }

    // Callback owners
    if (gc.vm.callbacks) |callback_heap| {
        const Ctx = struct {
            ctx: *FullMarkContext,
            fn visit(slot: *Cell, c: @This()) void {
                fullMarkSlot(slot, @ptrCast(c.ctx));
            }
        };
        const c = Ctx{ .ctx = ctx };
        callback_heap.iterateOwnersWithCtx(Ctx, Ctx.visit, c);
    }

    // Uninitialized code blocks (literals array roots)
    if (gc.vm.code) |code| {
        var iter = code.uninitialized_blocks.iterator();
        while (iter.next()) |entry| {
            const value = entry.value_ptr.*;
            const new_value = fullMarkValue(ctx, value);
            entry.value_ptr.* = new_value;

            const block_addr = entry.key_ptr.*;
            const block: *code_blocks.CodeBlock = @ptrFromInt(block_addr);
            markCodeBlockIfNeeded(gc, block);
        }
    }

    // Profiler sample threads (see gc.visitAllRoots).
    for (gc.vm.profiling_samples.items) |*sample| {
        fullMarkSlot(&sample.thread, @ptrCast(ctx));
    }
}

fn fullMarkContexts(gc: *GC, ctx: *FullMarkContext) void {
    for (gc.vm.active_contexts.items) |c| {
        fullMarkContext(c, ctx);
    }

    {
        const c = gc.vm.vm_asm.ctx;
        if (!c.isActive()) {
            fullMarkContext(c, ctx);
        }
    }
}

fn fullMarkStackSlots(top: Cell, seg: *const segments.Segment, ctx: *FullMarkContext) void {
    var ptr = seg.start;
    while (ptr <= top) : (ptr += @sizeOf(Cell)) {
        const slot: *Cell = @ptrFromInt(ptr);
        fullMarkSlot(slot, @ptrCast(ctx));
    }
}

fn fullMarkContext(c: *Context, ctx: *FullMarkContext) void {
    for (&c.context_objects) |*slot| {
        fullMarkSlot(slot, @ptrCast(ctx));
    }

    fullMarkCallstack(ctx, c);

    if (c.datastack_seg) |seg| {
        fullMarkStackSlots(c.datastack, seg, ctx);
    }

    if (c.retainstack_seg) |seg| {
        fullMarkStackSlots(c.retainstack, seg, ctx);
    }
}

fn fullMarkCallstack(ctx: *FullMarkContext, c: *Context) void {
    const code_heap = ctx.gc.vm.code orelse return;
    // Same frame walk as copying GC / become — mark (safe push) + mark code owners.
    const Fixup = struct {
        fctx: *FullMarkContext,
        pub fn visitSlot(self: *@This(), slot: *Cell) void {
            slot.* = fullMarkValue(self.fctx, slot.*);
        }
        pub fn visitCodeBlockOwner(self: *@This(), owner: *const code_blocks.CodeBlock) void {
            markCodeBlockIfNeeded(self.fctx.gc, @constCast(owner));
        }
    };
    var fixup = Fixup{ .fctx = ctx };
    slot_visitor.visitLiveCallstackRoots(Fixup, &fixup, code_heap, c.callstack_top, c.callstack_bottom);
}

// Inline helper: mark/copy a single slot value in-place.
// Eliminates the function pointer indirection that visitObjectSlots uses.
fn fullMarkSlotInline(slot: *Cell, ctx: *FullMarkContext) void {
    slot.* = fullMarkValue(ctx, slot.*);
}

// Inline helper: mark the code block for a word/quotation entry point.
fn fullMarkEntryPoint(gc: *GC, entry_point: Cell) void {
    if (entry_point != 0) {
        if (gc.vm.code) |code| {
            if (entry_point >= code.code_start and entry_point < code.code_start + code.code_size) {
                const block: *code_blocks.CodeBlock = @ptrFromInt(entry_point - @sizeOf(code_blocks.CodeBlock));
                markCodeBlockIfNeeded(gc, block);
            }
        }
    }
}

/// Fixup for full mark phase: marks/copies slot values and tracks code block entry points.
/// Uses fast mark stack push (assumes capacity was pre-allocated via ensureSlotCapacity).
const FullMarkFixup = struct {
    gc: *GC,
    ctx: *FullMarkContext,

    pub fn visitSlot(self: *@This(), slot: *Cell) void {
        slot.* = fullMarkValueFast(self.ctx, slot.*);
    }

    pub fn ensureSlotCapacity(self: *@This(), n: Cell) void {
        markStackEnsure(self.gc, n);
    }

    pub fn visitEntryPoint(self: *@This(), entry_point: Cell) void {
        fullMarkEntryPoint(self.gc, entry_point);
    }

    pub fn visitCodeBlockOwner(self: *@This(), owner: *const code_blocks.CodeBlock) void {
        markCodeBlockIfNeeded(self.gc, @constCast(owner));
    }

    pub fn visitCallstackObject(self: *@This(), stack: *layouts.Callstack) void {
        // Route through the shared walker so a callstack object's spilled
        // referents in nursery/aging get promoted to tenured and written back
        // (via visitSlot), not merely marked — otherwise a full GC would reset
        // nursery/aging out from under a live continuation's spill slots.
        const code_heap = self.gc.vm.code orelse return;
        slot_visitor.visitCallstackObjectRoots(@This(), self, code_heap, stack);
    }
};

// Process a data object from the mark stack using the generic slot visitor.
fn fullProcessDataObject(gc: *GC, addr: Cell, ctx: *FullMarkContext) void {
    var fixup = FullMarkFixup{ .gc = gc, .ctx = ctx };
    _ = slot_visitor.visitDataObjectSlots(FullMarkFixup, &fixup, addr);
}

fn fullProcessCodeBlock(gc: *GC, block: *code_blocks.CodeBlock, ctx: *FullMarkContext) void {
    if (block.isFree()) return;
    const code_heap = gc.vm.code orelse return;

    // Header fields (3 slots + reloc literals)
    markStackEnsure(gc, 3);
    fullMarkSlotInlineFast(@ptrCast(&block.owner), ctx);
    fullMarkSlotInlineFast(@ptrCast(&block.parameters), ctx);
    fullMarkSlotInlineFast(@ptrCast(&block.relocation), ctx);

    const is_uninitialized = code_heap.isBlockUninitialized(block);

    // Embedded literals (copy/update + mark)
    if (!is_uninitialized and block.relocation != layouts.false_object and
        layouts.hasTag(block.relocation, .byte_array))
    {
        const reloc_ba: *const layouts.ByteArray = @ptrFromInt(layouts.UNTAG(block.relocation));
        const reloc_cap = layouts.untagFixnumUnsigned(reloc_ba.capacity);
        if (reloc_cap > 0) {
            const reloc_data = reloc_ba.data();
            const reloc_count = reloc_cap / @sizeOf(code_blocks.RelocationEntry);
            // Each literal can push 1 mark + 1 copy
            markStackEnsure(gc, reloc_count);
            var param_index: Cell = 0;
            var modified = false;
            for (0..reloc_count) |i| {
                const entry_ptr: *const code_blocks.RelocationEntry =
                    @ptrCast(@alignCast(reloc_data + i * @sizeOf(code_blocks.RelocationEntry)));
                const entry = entry_ptr.*;
                const rel_type = entry.getType();
                if (rel_type == .literal) {
                    var op = code_blocks.InstructionOperand.init(entry, block, param_index);
                    const value = op.loadValue();
                    const value_unsigned: Cell = @bitCast(value);
                    if (!layouts.isImmediate(value_unsigned)) {
                        const new_value = fullMarkValueFast(ctx, value_unsigned);
                        if (new_value != value_unsigned) {
                            op.storeValue(@bitCast(new_value));
                            modified = true;
                        }
                    }
                }
                switch (rel_type) {
                    .vm => param_index += 1,
                    .dlsym => param_index += 2,
                    else => {},
                }
            }
            if (modified) block.flushIcache();
        }
    }

    // Embedded code pointers
    markEmbeddedCodePointers(gc, block, is_uninitialized);
}

pub fn fullDrainMarkStack(gc: *GC, ctx: *FullMarkContext) void {
    while (gc.mark_stack.items.len > 0) {
        const addr = gc.mark_stack.pop().?;
        if ((addr & 1) == 1) {
            const block: *code_blocks.CodeBlock = @ptrFromInt(addr - 1);
            fullProcessCodeBlock(gc, block, ctx);
        } else {
            fullProcessDataObject(gc, addr, ctx);
        }
    }
}

// Mark code block references embedded in instruction operands (full mark).
fn markEmbeddedCodePointers(gc: *GC, block: *code_blocks.CodeBlock, is_uninitialized: bool) void {
    const code = gc.vm.code orelse return;
    if (!code.blockHasCodePointers(block)) return;
    if (is_uninitialized) return;

    if (block.relocation == layouts.false_object) return;
    if (!layouts.hasTag(block.relocation, .byte_array)) return;

    const reloc_ba: *const layouts.ByteArray = @ptrFromInt(layouts.UNTAG(block.relocation));
    const reloc_cap = layouts.untagFixnumUnsigned(reloc_ba.capacity);
    if (reloc_cap == 0) return;

    const reloc_data = reloc_ba.data();
    const reloc_count = reloc_cap / @sizeOf(code_blocks.RelocationEntry);

    var param_index: Cell = 0;
    for (0..reloc_count) |i| {
        const entry_ptr: *const code_blocks.RelocationEntry = @ptrCast(@alignCast(reloc_data + i * @sizeOf(code_blocks.RelocationEntry)));
        const entry = entry_ptr.*;
        const rel_type = entry.getType();

        switch (rel_type) {
            .entry_point, .entry_point_pic, .entry_point_pic_tail => {
                const op = code_blocks.InstructionOperand.init(entry, block, param_index);
                const value = op.loadValue();
                const value_unsigned: Cell = @bitCast(value);
                if (value_unsigned >= 0x1000 and value_unsigned >= @sizeOf(code_blocks.CodeBlock)) {
                    const target_addr = value_unsigned - @sizeOf(code_blocks.CodeBlock);
                    if (target_addr >= code.code_start and target_addr < code.code_start + code.code_size) {
                        const target_block: *code_blocks.CodeBlock = @ptrFromInt(target_addr);
                        markCodeBlockIfNeeded(gc, target_block);
                    }
                }
            },
            else => {},
        }

        switch (rel_type) {
            .vm => param_index += 1,
            .dlsym => param_index += 2,
            else => {},
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const fixture = @import("gc_test_fixture.zig");
const testing = std.testing;

test "full mark marks objects reachable from the data stack and skips garbage" {
    var f: fixture.Fixture = undefined;
    try f.init();
    defer f.deinit();

    const a = f.tenuredArray(2, layouts.tagFixnum(1));
    const b = f.tenuredArray(2, layouts.tagFixnum(2)); // garbage
    const c = f.tenuredArray(2, layouts.tagFixnum(3));
    const d = f.tenuredArray(2, layouts.tagFixnum(4)); // garbage

    // a -> c, a rooted via the data stack; b and d unreachable.
    fixture.arrayAt(a).data()[0] = c;
    f.vm.push(a);

    f.fullMark();

    try testing.expect(f.isMarked(a));
    try testing.expect(f.isMarked(c));
    try testing.expect(!f.isMarked(b));
    try testing.expect(!f.isMarked(d));
    try testing.expectEqual(@as(usize, 0), f.gc.mark_stack.items.len);

    // Marking must not disturb tenured objects.
    try testing.expectEqual(c, fixture.arrayAt(a).data()[0]);
    try testing.expectEqual(a, f.vm.peek());
}

test "full mark visits every root kind" {
    var f: fixture.Fixture = undefined;
    try f.init();
    defer f.deinit();

    const via_retain = f.tenuredArray(1, layouts.false_object);
    const via_special = f.tenuredArray(1, layouts.false_object);
    const via_data_root = f.tenuredArray(1, layouts.false_object);
    const via_context_object = f.tenuredArray(1, layouts.false_object);
    const via_spare_ctx = f.tenuredArray(1, layouts.false_object);
    const garbage = f.tenuredArray(1, layouts.false_object);

    f.vm.vm_asm.ctx.pushRetain(via_retain);
    f.vm.vm_asm.special_objects[3] = via_special;
    var root_cell: Cell = via_data_root;
    try f.vm.data_roots.append(f.vm.allocator, &root_cell);
    defer _ = f.vm.data_roots.pop();
    f.vm.vm_asm.ctx.context_objects[0] = via_context_object;
    f.vm.vm_asm.spare_ctx.push(via_spare_ctx);

    f.fullMark();

    try testing.expect(f.isMarked(via_retain));
    try testing.expect(f.isMarked(via_special));
    try testing.expect(f.isMarked(via_data_root));
    try testing.expect(f.isMarked(via_context_object));
    try testing.expect(f.isMarked(via_spare_ctx));
    try testing.expect(!f.isMarked(garbage));
    // Tenured roots are not moved by marking.
    try testing.expectEqual(via_data_root, root_cell);
}

test "full mark follows cycles and shared references without re-marking" {
    var f: fixture.Fixture = undefined;
    try f.init();
    defer f.deinit();

    const a = f.tenuredArray(2, layouts.false_object);
    const b = f.tenuredArray(2, layouts.false_object);
    const shared = f.tenuredArray(1, layouts.tagFixnum(99));
    const garbage = f.tenuredArray(1, layouts.false_object);

    // a <-> b cycle, both point at shared.
    fixture.arrayAt(a).data()[0] = b;
    fixture.arrayAt(a).data()[1] = shared;
    fixture.arrayAt(b).data()[0] = a;
    fixture.arrayAt(b).data()[1] = shared;
    f.vm.push(a);

    f.fullMark();

    try testing.expect(f.isMarked(a));
    try testing.expect(f.isMarked(b));
    try testing.expect(f.isMarked(shared));
    try testing.expect(!f.isMarked(garbage));
    // Mark bits are per 16-byte line: three 32-byte arrays.
    const marked_lines = (2 * fixture.arraySize(2) + fixture.arraySize(1)) / layouts.data_alignment;
    try testing.expectEqual(marked_lines, f.heap.tenured.marks.countMarked());
    try testing.expectEqual(layouts.tagFixnum(99), fixture.arrayAt(shared).data()[0]);
}

test "full mark treats tuples through their layout and marks the layout too" {
    var f: fixture.Fixture = undefined;
    try f.init();
    defer f.deinit();

    const layout = f.tenuredTupleLayout(3);
    const referent = f.tenuredArray(1, layouts.false_object);
    const tuple = f.tenuredTuple(layout, layouts.tagFixnum(0));
    const garbage = f.tenuredArray(1, layouts.false_object);

    const t: *layouts.Tuple = @ptrFromInt(layouts.UNTAG(tuple));
    t.data()[2] = referent;
    f.vm.push(tuple);

    f.fullMark();

    try testing.expect(f.isMarked(tuple));
    try testing.expect(f.isMarked(layout));
    try testing.expect(f.isMarked(referent));
    try testing.expect(!f.isMarked(garbage));
}

test "full mark promotes nursery objects to tenured and rewrites the root" {
    var f: fixture.Fixture = undefined;
    try f.init();
    defer f.deinit();

    const used_before = f.heap.tenured.usedBytes();
    const t = f.tenuredArray(1, layouts.tagFixnum(5));
    const garbage = f.tenuredArray(1, layouts.false_object);

    // n (nursery) -> n2 (nursery) -> t (tenured); root is a data root.
    const n2 = f.nurseryArray(1, t);
    const n = f.nurseryArray(2, n2);
    try testing.expect(f.inNursery(n));
    try testing.expect(f.inNursery(n2));

    var root: Cell = n;
    try f.vm.data_roots.append(f.vm.allocator, &root);
    defer _ = f.vm.data_roots.pop();

    f.fullMark();

    // Root now points into tenured, at a marked copy with intact contents.
    try testing.expect(root != n);
    try testing.expect(f.inTenured(root));
    try testing.expect(f.isMarked(root));
    try testing.expectEqual(layouts.TAG(n), layouts.TAG(root));
    const new_n = fixture.arrayAt(root);
    try testing.expectEqual(@as(Cell, 2), new_n.getCapacity());

    // Its slot was rewritten to the promoted copy of n2, which itself points at t.
    const new_n2 = new_n.data()[0];
    try testing.expect(new_n2 != n2);
    try testing.expect(f.inTenured(new_n2));
    try testing.expect(f.isMarked(new_n2));
    try testing.expectEqual(t, fixture.arrayAt(new_n2).data()[0]);
    try testing.expectEqual(new_n2, new_n.data()[1]);
    try testing.expect(f.isMarked(t));
    try testing.expect(!f.isMarked(garbage));

    // The nursery originals were turned into forwarding pointers.
    try testing.expect(fixture.objectAt(n).isForwardingPointer());
    try testing.expect(fixture.objectAt(n2).isForwardingPointer());
    try testing.expectEqual(layouts.UNTAG(root), @intFromPtr(fixture.objectAt(n).forwardingPointer()));

    // Promotion consumed tenured space for exactly the two copies.
    const promoted = fixture.arraySize(2) + fixture.arraySize(1);
    try testing.expectEqual(used_before + fixture.arraySize(1) * 2 + promoted, f.heap.tenured.usedBytes());
}

test "full mark promotes an object referenced twice only once" {
    var f: fixture.Fixture = undefined;
    try f.init();
    defer f.deinit();

    const n = f.nurseryArray(1, layouts.tagFixnum(7));
    const holder = f.tenuredArray(2, n);
    f.vm.push(holder);
    f.vm.push(n);

    f.fullMark();

    const h = fixture.arrayAt(holder);
    try testing.expect(f.inTenured(h.data()[0]));
    try testing.expectEqual(h.data()[0], h.data()[1]);
    try testing.expectEqual(h.data()[0], f.vm.peek());
    try testing.expectEqual(layouts.tagFixnum(7), fixture.arrayAt(h.data()[0]).data()[0]);
    // Only holder and one promoted copy are marked (lines of 16 bytes).
    const marked_lines = (fixture.arraySize(2) + fixture.arraySize(1)) / layouts.data_alignment;
    try testing.expectEqual(marked_lines, f.heap.tenured.marks.countMarked());
}

test "full mark ignores immediates and false in roots and slots" {
    var f: fixture.Fixture = undefined;
    try f.init();
    defer f.deinit();

    const a = f.tenuredArray(3, layouts.tagFixnum(-1));
    fixture.arrayAt(a).data()[1] = layouts.false_object;
    f.vm.push(layouts.tagFixnum(123));
    f.vm.push(layouts.false_object);
    f.vm.push(a);

    f.fullMark();

    try testing.expect(f.isMarked(a));
    try testing.expectEqual(fixture.arraySize(3) / layouts.data_alignment, f.heap.tenured.marks.countMarked());
    try testing.expectEqual(layouts.tagFixnum(-1), fixture.arrayAt(a).data()[0]);
    try testing.expectEqual(layouts.false_object, fixture.arrayAt(a).data()[1]);
}
