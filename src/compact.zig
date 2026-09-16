// compact.zig - Compaction phase for Factor VM garbage collector
// Handles mark-compact GC: moving marked objects, fixing up pointers,
// updating callstacks, code blocks, and instruction operands.
//
// Extracted from gc.zig to reduce file size.

const std = @import("std");
const builtin = @import("builtin");

const c_api = @import("c_api.zig");
const code_blocks = @import("code_blocks.zig");
const contexts = @import("contexts.zig");
const data_heap_mod = @import("data_heap.zig");
const free_list_mod = @import("free_list.zig");
const gc_mod = @import("gc.zig");
const icache = @import("icache.zig");
const segments = @import("segments.zig");
const slot_visitor = @import("slot_visitor.zig");
const sweep_mod = @import("sweep.zig");
const layouts = @import("layouts.zig");
const mark_bits = @import("mark_bits.zig");
const spill_slots = @import("spill_slots.zig");
const trampolines = @import("trampolines.zig");
const vm_mod = @import("vm.zig");

const Cell = layouts.Cell;
const Context = contexts.Context;
const GC = gc_mod.GarbageCollector;

pub const CompactionFixup = struct {
    data_marks: *mark_bits.MarkBits,
    code_marks: ?*mark_bits.MarkBits,
    data_finger: *Cell,
    code_finger: *Cell,

    fn fixupData(self: *CompactionFixup, addr: Cell) Cell {
        return self.data_marks.forwardBlock(addr);
    }

    fn fixupCode(self: *CompactionFixup, addr: Cell) Cell {
        if (self.code_marks) |marks| {
            return marks.forwardBlock(addr);
        }
        return addr;
    }

    fn translateData(self: *CompactionFixup, addr: Cell) Cell {
        if (addr < self.data_finger.*) {
            return self.fixupData(addr);
        }
        return addr;
    }

    fn translateCode(self: *CompactionFixup, addr: Cell) Cell {
        if (self.code_marks == null) return addr;
        if (addr < self.code_finger.*) {
            return self.fixupCode(addr);
        }
        return addr;
    }
};

fn memmoveBytes(dest: Cell, src: Cell, size: Cell) void {
    if (dest == src or size == 0) return;
    const n: usize = @intCast(size);
    const dst: [*]u8 = @ptrFromInt(dest);
    const src_ptr: [*]const u8 = @ptrFromInt(src);
    @memmove(dst[0..n], src_ptr[0..n]);
}

fn fixupSlotValue(fixup: *CompactionFixup, value: Cell) Cell {
    if (layouts.isImmediate(value)) return value;
    const fixed = fixup.fixupData(layouts.UNTAG(value));
    return layouts.RETAG(fixed, layouts.TAG(value));
}

fn fixupSlot(fixup: *CompactionFixup, slot: *Cell) void {
    slot.* = fixupSlotValue(fixup, slot.*);
}

fn objectSizeForCompaction(addr: Cell, fixup: *CompactionFixup) Cell {
    const obj: *layouts.Object = @ptrFromInt(addr);

    if (obj.isFree()) {
        return obj.header & ~@as(Cell, 7);
    }

    return switch (obj.getType()) {
        .array => blk: {
            const arr: *layouts.Array = @ptrFromInt(addr);
            std.debug.assert(layouts.hasTag(arr.capacity, .fixnum));
            const capacity = layouts.untagFixnumUnsigned(arr.capacity);
            break :blk layouts.alignCell(@sizeOf(layouts.Array) + capacity * @sizeOf(Cell), layouts.data_alignment);
        },
        .byte_array => blk: {
            const arr: *layouts.ByteArray = @ptrFromInt(addr);
            std.debug.assert(layouts.hasTag(arr.capacity, .fixnum));
            const capacity = layouts.untagFixnumUnsigned(arr.capacity);
            break :blk layouts.alignCell(@sizeOf(layouts.ByteArray) + capacity, layouts.data_alignment);
        },
        .string => blk: {
            const str: *layouts.String = @ptrFromInt(addr);
            std.debug.assert(layouts.hasTag(str.length, .fixnum));
            const len = layouts.untagFixnumUnsigned(str.length);
            break :blk layouts.alignCell(@sizeOf(layouts.String) + len, layouts.data_alignment);
        },
        .bignum => blk: {
            const bn: *layouts.Bignum = @ptrFromInt(addr);
            std.debug.assert(layouts.hasTag(bn.capacity, .fixnum));
            const capacity = layouts.untagFixnumUnsigned(bn.capacity);
            break :blk layouts.alignCell(@sizeOf(layouts.Bignum) + capacity * @sizeOf(Cell), layouts.data_alignment);
        },
        .tuple => blk: {
            const tuple: *layouts.Tuple = @ptrFromInt(addr);
            const layout_addr = fixup.translateData(layouts.UNTAG(tuple.layout));
            const layout: *layouts.TupleLayout = @ptrFromInt(layout_addr);
            const slots = layouts.untagFixnumUnsigned(layout.size);
            break :blk layouts.alignCell(@sizeOf(layouts.Tuple) + slots * @sizeOf(Cell), layouts.data_alignment);
        },
        .quotation => layouts.alignCell(@sizeOf(layouts.Quotation), layouts.data_alignment),
        .word => layouts.alignCell(@sizeOf(layouts.Word), layouts.data_alignment),
        .wrapper => layouts.alignCell(@sizeOf(layouts.Wrapper), layouts.data_alignment),
        .float => layouts.alignCell(@sizeOf(layouts.BoxedFloat), layouts.data_alignment),
        .alien => layouts.alignCell(@sizeOf(layouts.Alien), layouts.data_alignment),
        .dll => layouts.alignCell(@sizeOf(layouts.Dll), layouts.data_alignment),
        .callstack => blk: {
            const cs: *layouts.Callstack = @ptrFromInt(addr);
            std.debug.assert(layouts.hasTag(cs.length, .fixnum));
            const len = layouts.untagFixnumUnsigned(cs.length);
            break :blk layouts.alignCell(@sizeOf(layouts.Callstack) + len, layouts.data_alignment);
        },
        .fixnum, .f => layouts.data_alignment,
    };
}

fn requireParameters(block: *code_blocks.CodeBlock) *const layouts.Array {
    std.debug.assert(block.parameters != layouts.false_object);
    std.debug.assert(layouts.hasTag(block.parameters, .array));
    return @ptrFromInt(layouts.UNTAG(block.parameters));
}

fn requireParameter(block: *code_blocks.CodeBlock, param_index: Cell) Cell {
    const params = requireParameters(block);
    std.debug.assert(param_index < layouts.untagFixnumUnsigned(params.capacity));
    return params.data()[param_index];
}

fn resetFreeListForCompaction(free_list: *free_list_mod.FreeListAllocator, free_start: Cell, heap_end: Cell) void {
    free_list.reset();

    if (free_start >= heap_end) return;
    const free_size = heap_end - free_start;
    if (free_size >= free_list_mod.min_block_size) {
        free_list.addFreeBlock(free_start, free_size);
    }
}

// --- Functions requiring GC pointer ---

fn fixupCallstackSlots(gc: *GC, ctx: *Context, fixup: *CompactionFixup) void {
    const code_heap = gc.vm.code orelse return;
    const blocks = code_heap.all_blocks_sorted.items;
    if (blocks.len == 0) return;

    var top = ctx.callstack_top;
    const bottom = ctx.callstack_bottom;
    if (top == 0 or bottom == 0 or top >= bottom) return;

    const LEAF_FRAME_SIZE: Cell = code_blocks.CodeBlock.LEAF_FRAME_SIZE;
    const is_arm64 = builtin.cpu.arch == .aarch64;

    while (top < bottom) {
        // Return address: frame_top+0 (x86-64) / frame_top+8 (arm64, where +0
        // holds the predecessor frame pointer). See iterateCallstack.
        const addr = @as(*const Cell, @ptrFromInt(top + contexts.FRAME_RETURN_ADDRESS)).*;
        if (addr == 0) break;

        // arm64 live frames are chained by absolute frame pointer at *(top).
        const next_top: Cell = if (is_arm64) @as(*const Cell, @ptrFromInt(top)).* else 0;

        // Binary search all_blocks_sorted (old addresses)
        const ub = std.sort.upperBound(Cell, blocks, addr, layouts.orderCell);
        if (ub == 0) {
            if (is_arm64) {
                if (next_top <= top) break;
                top = next_top;
            } else {
                top += LEAF_FRAME_SIZE;
            }
            continue;
        }
        const old_block_addr = blocks[ub - 1];

        // Get new block address via forwarding map; read from NEW address
        const new_block_addr = fixup.translateCode(old_block_addr);
        const compiled: *const code_blocks.CodeBlock = @ptrFromInt(new_block_addr);

        // Compute offset using old entry point (arithmetic only)
        const old_entry_point = old_block_addr + @sizeOf(code_blocks.CodeBlock);
        const delta = if (addr > old_entry_point) addr - old_entry_point else 0;

        if (compiled.blockGcInfo()) |gc_info| {
            const return_address_offset: u32 = @intCast(delta);
            if (gc_info.returnAddressIndex(return_address_offset)) |callsite| {
                const stack_pointer: [*]Cell = @ptrFromInt(top);
                const Visit = struct {
                    fn slot(slot_ptr: *Cell, fx: *CompactionFixup) void {
                        fixupSlot(fx, slot_ptr);
                    }
                };
                spill_slots.visit(*CompactionFixup, stack_pointer, gc_info, callsite, fixup, Visit.slot);
            }
        }

        if (is_arm64) {
            if (next_top <= top) break;
            top = next_top;
        } else {
            const natural_frame_size = compiled.stackFrameSize();
            top += if (natural_frame_size > 0 and delta > 0) natural_frame_size else LEAF_FRAME_SIZE;
        }
    }
}

fn fixupCallstackObjectSlots(gc: *GC, stack: *layouts.Callstack, fixup: *CompactionFixup) void {
    const code_heap = gc.vm.code orelse return;
    const blocks = code_heap.all_blocks_sorted.items;
    if (blocks.len == 0) return;
    const frame_length = layouts.untagFixnumUnsigned(stack.length);
    if (frame_length == 0) return;

    const LEAF_FRAME_SIZE: Cell = code_blocks.CodeBlock.LEAF_FRAME_SIZE;
    const is_arm64 = builtin.cpu.arch == .aarch64;
    var frame_offset: Cell = 0;

    while (frame_offset < frame_length) {
        const frame_top = stack.frameTopAt(frame_offset);

        // arm64 callstack objects store the (relative) frame size at slot 0, and
        // the return address at +8; x86-64 stores the return address at +0.
        const arm_frame_size: Cell = if (is_arm64) @as(*const Cell, @ptrFromInt(frame_top)).* else 0;
        if (is_arm64 and (arm_frame_size == 0 or frame_offset + arm_frame_size > frame_length)) break;

        const addr = @as(*const Cell, @ptrFromInt(frame_top + contexts.FRAME_RETURN_ADDRESS)).*;
        if (addr == 0) break;

        const ub = std.sort.upperBound(Cell, blocks, addr, layouts.orderCell);
        if (ub == 0) {
            frame_offset += if (is_arm64) arm_frame_size else LEAF_FRAME_SIZE;
            continue;
        }
        const old_block_addr = blocks[ub - 1];

        const old_block: *const code_blocks.CodeBlock = @ptrFromInt(old_block_addr);

        // Get compiled block (may be at new address if code forwarding is active)
        const compiled_addr = fixup.translateCode(old_block_addr);
        const compiled: *const code_blocks.CodeBlock = @ptrFromInt(compiled_addr);

        if (compiled.blockGcInfo()) |gc_info| {
            const old_entry_point = old_block.entryPoint();
            const return_address_offset: u32 = @intCast(if (addr >= old_entry_point) addr - old_entry_point else 0);
            if (gc_info.returnAddressIndex(return_address_offset)) |callsite| {
                const stack_pointer: [*]Cell = @ptrFromInt(frame_top);
                const Visit = struct {
                    fn slot(slot_ptr: *Cell, fx: *CompactionFixup) void {
                        fixupSlot(fx, slot_ptr);
                    }
                };
                spill_slots.visit(*CompactionFixup, stack_pointer, gc_info, callsite, fixup, Visit.slot);
            }
        }

        if (is_arm64) {
            frame_offset += arm_frame_size;
        } else {
            const old_entry_point2 = old_block.entryPoint();
            const delta = if (addr > old_entry_point2) addr - old_entry_point2 else 0;
            const natural_frame_size = compiled.stackFrameSize();
            frame_offset += if (natural_frame_size > 0 and delta > 0) natural_frame_size else LEAF_FRAME_SIZE;
        }
    }
}

fn fixupCallstackReturnAddresses(gc: *GC, ctx: *Context, fixup: *CompactionFixup) void {
    const code_heap = gc.vm.code orelse return;
    const blocks = code_heap.all_blocks_sorted.items;
    if (blocks.len == 0) return;

    var top = ctx.callstack_top;
    const bottom = ctx.callstack_bottom;
    if (top == 0 or bottom == 0 or top >= bottom) return;

    const LEAF_FRAME_SIZE: Cell = code_blocks.CodeBlock.LEAF_FRAME_SIZE;
    const is_arm64 = builtin.cpu.arch == .aarch64;

    while (top < bottom) {
        // Return address slot: top+0 (x86-64) / top+8 (arm64).
        const addr_ptr: *Cell = @ptrFromInt(top + contexts.FRAME_RETURN_ADDRESS);
        const addr = addr_ptr.*;
        if (addr == 0) break;

        // Read the predecessor frame pointer (arm64) before mutating the frame.
        const next_top: Cell = if (is_arm64) @as(*const Cell, @ptrFromInt(top)).* else 0;

        // Binary search all_blocks_sorted (old addresses) to find the owner
        const ub = std.sort.upperBound(Cell, blocks, addr, layouts.orderCell);
        if (ub == 0) {
            if (is_arm64) {
                if (next_top <= top) break;
                top = next_top;
            } else {
                top += LEAF_FRAME_SIZE;
            }
            continue;
        }
        const old_block_addr = blocks[ub - 1];

        const new_block_addr = fixup.translateCode(old_block_addr);
        const new_block: *const code_blocks.CodeBlock = @ptrFromInt(new_block_addr);

        const old_entry_point = old_block_addr + @sizeOf(code_blocks.CodeBlock);
        const offset = if (addr > old_entry_point) addr - old_entry_point else 0;

        // Update return address to point into the new block
        addr_ptr.* = new_block.entryPoint() + offset;

        if (is_arm64) {
            if (next_top <= top) break;
            top = next_top;
        } else {
            const natural_frame_size = new_block.stackFrameSize();
            top += if (natural_frame_size > 0 and offset > 0) natural_frame_size else LEAF_FRAME_SIZE;
        }
    }
}

fn fixupCallstackObjectReturnAddresses(gc: *GC, stack: *layouts.Callstack, fixup: *CompactionFixup) void {
    const code_heap = gc.vm.code orelse return;
    const blocks = code_heap.all_blocks_sorted.items;
    if (blocks.len == 0) return;
    const frame_length = layouts.untagFixnumUnsigned(stack.length);
    if (frame_length == 0) return;

    const LEAF_FRAME_SIZE: Cell = code_blocks.CodeBlock.LEAF_FRAME_SIZE;
    const is_arm64 = builtin.cpu.arch == .aarch64;
    var frame_offset: Cell = 0;

    while (frame_offset < frame_length) {
        const frame_top = stack.frameTopAt(frame_offset);

        // arm64 objects: (relative) frame size at slot 0, return address at +8.
        const arm_frame_size: Cell = if (is_arm64) @as(*const Cell, @ptrFromInt(frame_top)).* else 0;
        if (is_arm64 and (arm_frame_size == 0 or frame_offset + arm_frame_size > frame_length)) break;

        const addr_ptr: *Cell = @ptrFromInt(frame_top + contexts.FRAME_RETURN_ADDRESS);
        const addr = addr_ptr.*;
        if (addr == 0) break;

        const ub = std.sort.upperBound(Cell, blocks, addr, layouts.orderCell);
        if (ub == 0) {
            frame_offset += if (is_arm64) arm_frame_size else LEAF_FRAME_SIZE;
            continue;
        }
        const old_block_addr = blocks[ub - 1];

        const new_block_addr = fixup.fixupCode(old_block_addr);
        const old_block: *const code_blocks.CodeBlock = @ptrFromInt(old_block_addr);
        const old_entry_point = old_block.entryPoint();
        const offset = if (addr >= old_entry_point) addr - old_entry_point else 0;
        const new_entry_point = new_block_addr + @sizeOf(code_blocks.CodeBlock);
        addr_ptr.* = new_entry_point + offset;

        if (is_arm64) {
            frame_offset += arm_frame_size;
        } else {
            const natural_frame_size = old_block.stackFrameSize();
            frame_offset += if (natural_frame_size > 0 and offset > 0) natural_frame_size else LEAF_FRAME_SIZE;
        }
    }
}

/// Fixup for compaction: updates data pointers through the forwarding map.
const CompactionSlotFixup = struct {
    gc: *GC,
    fixup: *CompactionFixup,

    pub fn visitSlot(self: *@This(), slot: *Cell) void {
        fixupSlot(self.fixup, slot);
    }

    pub fn resolveTupleLayout(self: *@This(), layout: Cell) Cell {
        return self.fixup.translateData(layouts.UNTAG(layout));
    }

    pub fn visitCallstackObject(self: *@This(), stack: *layouts.Callstack) void {
        fixupCallstackObjectSlots(self.gc, stack, self.fixup);
    }
};

fn fixupObjectSlots(gc: *GC, addr: Cell, fixup: *CompactionFixup) void {
    var slot_fixup = CompactionSlotFixup{ .gc = gc, .fixup = fixup };
    _ = slot_visitor.visitDataObjectSlots(CompactionSlotFixup, &slot_fixup, addr);
}

fn fixupObjectCodePointers(gc: *GC, addr: Cell, fixup: *CompactionFixup) void {
    const obj: *layouts.Object = @ptrFromInt(addr);
    switch (obj.getType()) {
        .word => {
            const word: *layouts.Word = @ptrFromInt(addr);
            if (word.entry_point != 0) {
                // entry_point = code_block_addr + sizeof(CodeBlock)
                // Forward the code_block address, then recompute entry_point
                const code_block_addr = word.entry_point - @sizeOf(code_blocks.CodeBlock);
                const new_code_addr = fixup.fixupCode(code_block_addr);
                word.entry_point = new_code_addr + @sizeOf(code_blocks.CodeBlock);
            }
        },
        .quotation => {
            const quot: *layouts.Quotation = @ptrFromInt(addr);
            if (quot.entry_point != 0) {
                const code_block_addr = quot.entry_point - @sizeOf(code_blocks.CodeBlock);
                const new_code_addr = fixup.fixupCode(code_block_addr);
                quot.entry_point = new_code_addr + @sizeOf(code_blocks.CodeBlock);
            }
        },
        .callstack => {
            const stack: *layouts.Callstack = @ptrFromInt(addr);
            fixupCallstackObjectReturnAddresses(gc, stack, fixup);
        },
        else => {},
    }
}

fn fixupStackSlots(top: Cell, seg: *const segments.Segment, fixup: *CompactionFixup) void {
    var ptr = seg.start;
    while (ptr <= top) : (ptr += @sizeOf(Cell)) {
        const slot: *Cell = @ptrFromInt(ptr);
        fixupSlot(fixup, slot);
    }
}

fn fixupContextRoots(gc: *GC, ctx: *Context, fixup: *CompactionFixup) void {
    for (&ctx.context_objects) |*slot| {
        fixupSlot(fixup, slot);
    }
    fixupCallstackSlots(gc, ctx, fixup);

    if (ctx.datastack_seg) |seg| {
        fixupStackSlots(ctx.datastack, seg, fixup);
    }
    if (ctx.retainstack_seg) |seg| {
        fixupStackSlots(ctx.retainstack, seg, fixup);
    }
}

fn computeExternalRelocationValue(gc: *GC, block: *code_blocks.CodeBlock, rel_type: code_blocks.RelocationType, param_index: Cell) Cell {
    const vm_ptr = @intFromPtr(&gc.vm.vm_asm);
    const cards_offset = gc.vm.vm_asm.cards_offset;
    const decks_offset = gc.vm.vm_asm.decks_offset;
    const megamorphic_hits = @intFromPtr(&gc.vm.dispatch_stats.megamorphic_cache_hits);
    const inline_cache_miss = @intFromPtr(&c_api.inline_cache_miss);
    const safepoint_page = if (gc.vm.code) |code| code.safepoint_page else unreachable;

    return switch (rel_type) {
        .this => block.entryPoint(),
        .dlsym => blk: {
            const params = requireParameters(block);
            std.debug.assert(param_index + 1 < layouts.untagFixnumUnsigned(params.capacity));
            break :blk code_blocks.computeDlsymAddress(params, param_index);
        },
        .vm => blk: {
            const offset_value = requireParameter(block, param_index);
            std.debug.assert(layouts.hasTag(offset_value, .fixnum));
            const base: isize = @bitCast(vm_ptr);
            break :blk @bitCast(base + layouts.untagFixnum(offset_value));
        },
        .cards_offset => cards_offset,
        .decks_offset => decks_offset,
        .megamorphic_cache_hits => megamorphic_hits,
        .inline_cache_miss => inline_cache_miss,
        .safepoint => safepoint_page,
        .trampoline => if (builtin.cpu.arch == .aarch64) @intFromPtr(&trampolines.trampoline) else unreachable,
        .trampoline2 => if (builtin.cpu.arch == .aarch64) @intFromPtr(&trampolines.trampoline2) else unreachable,
        .entry_point,
        .entry_point_pic,
        .entry_point_pic_tail,
        .here,
        .literal,
        .untagged,
        => unreachable,
    };
}

fn updateInstructionOperandsForCompaction(gc: *GC, block: *code_blocks.CodeBlock, old_entry_point: Cell, fixup: *CompactionFixup) bool {
    if (block.relocation == layouts.false_object) return false;
    if (!layouts.hasTag(block.relocation, .byte_array)) return false;

    const reloc_ba: *const layouts.ByteArray = @ptrFromInt(layouts.UNTAG(block.relocation));
    const reloc_cap = layouts.untagFixnumUnsigned(reloc_ba.capacity);
    if (reloc_cap == 0) return false;

    const reloc_data = reloc_ba.data();
    const reloc_count = reloc_cap / @sizeOf(code_blocks.RelocationEntry);

    var param_index: Cell = 0;

    for (0..reloc_count) |i| {
        const entry_ptr: *const code_blocks.RelocationEntry = @ptrCast(@alignCast(reloc_data + i * @sizeOf(code_blocks.RelocationEntry)));

        // Validate class - assert on entries with reserved/invalid class values
        const raw_class = @as(u4, @truncate((entry_ptr.value & 0x0F000000) >> 24));
        const valid_class = switch (raw_class) {
            0, 1, 2, 3, 4, 5, 6, 10, 11 => true,
            else => false,
        };
        std.debug.assert(valid_class);

        const rel_type = entry_ptr.getType();
        var op = code_blocks.InstructionOperand.init(entry_ptr.*, block, 0);

        const old_offset = old_entry_point + @as(Cell, entry_ptr.getOffset());
        const old_value_i64 = op.loadValueRelative(old_offset);
        const old_value: Cell = @bitCast(old_value_i64);

        const new_value: Cell = switch (rel_type) {
            .literal => fixupSlotValue(fixup, old_value),
            .entry_point, .entry_point_pic, .entry_point_pic_tail, .here => blk: {
                const tag = layouts.TAG(old_value);
                const code_addr = layouts.UNTAG(old_value);
                const fixed_addr = fixup.fixupCode(code_addr);
                break :blk layouts.RETAG(fixed_addr, tag);
            },
            .this => block.entryPoint(),
            .untagged => old_value,
            else => computeExternalRelocationValue(gc, block, rel_type, param_index),
        };

        // Always store: even if the absolute target didn't change, relative
        // encodings must be re-written because the instruction moved.
        op.storeValue(@bitCast(new_value));

        param_index += entry_ptr.numberOfParameters();
    }

    return true;
}

fn updateUninitializedBlocksForCompaction(gc: *GC, fixup: *CompactionFixup) void {
    const code = gc.vm.code orelse return;
    const alloc = gc.allocator;

    if (code.uninitialized_blocks.count() == 0) return;

    var new_map = code.uninitialized_blocks_scratch;
    new_map.clearRetainingCapacity();
    new_map.ensureTotalCapacity(alloc, code.uninitialized_blocks.count()) catch @panic("OOM");

    var iter = code.uninitialized_blocks.iterator();
    while (iter.next()) |entry| {
        const old_block = entry.key_ptr.*;
        const old_value = entry.value_ptr.*;
        const new_block = fixup.fixupCode(old_block);
        const new_value = fixupSlotValue(fixup, old_value);
        new_map.putAssumeCapacity(new_block, new_value);
    }

    code.uninitialized_blocks_scratch = code.uninitialized_blocks;
    code.uninitialized_blocks = new_map;
}

fn updateCodeRootsForCompaction(gc: *GC, marks: *mark_bits.MarkBits) void {
    const mask: Cell = ~@as(Cell, layouts.data_alignment) + 1;
    for (gc.vm.code_roots.items) |root| {
        if (!root.valid) continue;
        const block = root.value & mask;
        const offset = root.value - block;
        if (marks.isMarked(block)) {
            const new_block = marks.forwardBlock(block);
            root.value = new_block + offset;
        } else {
            root.valid = false;
        }
    }
}

// Main compaction entry point
pub fn compactPhase(gc: *GC, compact_code_heap: bool) void {
    const tenured = &gc.heap.tenured;
    tenured.marks.computeForwarding();

    var code_marks: ?*mark_bits.MarkBits = null;
    var code_start: Cell = 0;
    var code_end: Cell = 0;

    if (compact_code_heap) {
        if (gc.vm.code) |code| {
            code_start = code.code_start;
            code_end = code.code_start + code.code_size;
            if (code.marks) |marks| {
                marks.computeForwarding();
                code_marks = marks;
            }
        }
    }

    var data_finger: Cell = tenured.start;
    var code_finger: Cell = code_start;
    var fixup = CompactionFixup{
        .data_marks = &tenured.marks,
        .code_marks = code_marks,
        .data_finger = &data_finger,
        .code_finger = &code_finger,
    };

    // Flush any pending code block addresses into the sorted list.
    // fixupCallstackSlots / fixupCallstackReturnAddresses binary-search
    // all_blocks_sorted directly (not codeBlockForAddress which also
    // checks pending_blocks).  Without this flush, recently-compiled
    // blocks would be missed, causing wrong block lookups and corrupt
    // return addresses.
    if (gc.vm.code) |code| {
        code.flushPending();
    }

    // Update uninitialized block map before moving code blocks
    if (compact_code_heap) {
        updateUninitializedBlocksForCompaction(gc, &fixup);
    }

    // Clear object start map; rebuild while compacting
    tenured.object_start.clear();

    // Compact tenured space
    var data_dest: Cell = tenured.start;
    var scan: Cell = tenured.start;
    while (scan < tenured.end) {
        const is_marked = tenured.marks.isMarked(scan);
        const size = if (is_marked)
            objectSizeForCompaction(scan, &fixup)
        else
            tenured.marks.unmarkedBlockSize(scan);

        if (size == 0) break;

        if (is_marked) {
            data_finger = scan + size;

            if (data_dest != scan) {
                memmoveBytes(data_dest, scan, size);
            }

            fixupObjectSlots(gc, data_dest, &fixup);
            fixupObjectCodePointers(gc, data_dest, &fixup);

            tenured.object_start.recordObjectStart(data_dest);
            data_dest += size;
        }

        scan += size;
    }

    // Rebuild free list with a single block at the end
    resetFreeListForCompaction(tenured.free_list, data_dest, tenured.end);

    // Compact code heap if present
    if (gc.vm.code) |code| {
        if (code_marks) |marks| {
            var code_dest: Cell = code_start;
            var code_scan: Cell = code_start;

            while (code_scan < code_end) {
                const size = if (marks.isMarked(code_scan))
                    (@as(*code_blocks.CodeBlock, @ptrFromInt(code_scan))).size()
                else
                    marks.unmarkedBlockSize(code_scan);

                if (size == 0) break;

                if (marks.isMarked(code_scan)) {
                    code_finger = code_scan + size;
                    if (code_dest != code_scan) {
                        memmoveBytes(code_dest, code_scan, size);
                    }

                    const new_block: *code_blocks.CodeBlock = @ptrFromInt(code_dest);
                    const old_entry_point = code_scan + @sizeOf(code_blocks.CodeBlock);

                    // Fix data pointers in the block header
                    new_block.owner = fixupSlotValue(&fixup, new_block.owner);
                    new_block.parameters = fixupSlotValue(&fixup, new_block.parameters);
                    new_block.relocation = fixupSlotValue(&fixup, new_block.relocation);

                    // Fix embedded literals and code pointers unless uninitialized
                    if (!code.isUninitializedAddress(@intFromPtr(new_block))) {
                        _ = updateInstructionOperandsForCompaction(gc, new_block, old_entry_point, &fixup);
                    }

                    code_dest += size;
                }

                code_scan += size;
            }

            if (code.free_list) |alloc| {
                resetFreeListForCompaction(alloc, code_dest, code_end);
                alloc.validateFreeList();
            }
        }
    }

    // When not compacting code, still fix data pointers in live code blocks
    // (owner, parameters, relocation, embedded literals) since data objects moved.
    if (!compact_code_heap) {
        if (gc.vm.code) |code| {
            if (code.marks) |marks| {
                var code_scan: Cell = code.code_start;
                const code_end_addr2 = code.code_start + code.code_size;
                while (code_scan < code_end_addr2) {
                    const block: *code_blocks.CodeBlock = @ptrFromInt(code_scan);
                    const blk_size = block.size();
                    if (blk_size == 0) break;

                    if (marks.isMarked(code_scan) and !block.isFree()) {
                        block.owner = fixupSlotValue(&fixup, block.owner);
                        block.parameters = fixupSlotValue(&fixup, block.parameters);
                        block.relocation = fixupSlotValue(&fixup, block.relocation);

                        if (!code.isUninitializedAddress(code_scan)) {
                            if (updateInstructionOperandsForCompaction(gc, block, block.entryPoint(), &fixup)) {
                                block.flushIcache();
                            }
                        }
                    }

                    code_scan += blk_size;
                }
            }
        }
    }

    // Fix up uninitialized_blocks map values (data pointers).
    // not just code compaction. Without this, values in the map become stale
    // after data-only compaction when the pointed-to objects move.
    if (!compact_code_heap) {
        if (gc.vm.code) |code| {
            var uninit_iter = code.uninitialized_blocks.iterator();
            while (uninit_iter.next()) |entry| {
                entry.value_ptr.* = fixupSlotValue(&fixup, entry.value_ptr.*);
            }
        }
    }

    // Fix up all roots (data pointers)
    for (&gc.vm.vm_asm.special_objects) |*slot| {
        fixupSlot(&fixup, slot);
    }

    for (gc.vm.active_contexts.items) |ctx| {
        fixupContextRoots(gc, ctx, &fixup);
    }

    {
        const ctx = gc.vm.vm_asm.ctx;
        if (!ctx.isActive()) {
            fixupContextRoots(gc, ctx, &fixup);
        }
    }

    for (gc.vm.data_roots.items) |root_ptr| {
        fixupSlot(&fixup, root_ptr);
    }

    // Profiler sample threads (see gc.visitAllRoots).
    for (gc.vm.profiling_samples.items) |*sample| {
        fixupSlot(&fixup, &sample.thread);
    }

    if (gc.vm.callbacks) |callback_heap| {
        const seg = callback_heap.segment orelse null;
        if (seg) |s| {
            var current = s.start;
            while (current < s.end) {
                const block: *code_blocks.CodeBlock = @ptrFromInt(current);
                const block_size = block.size();
                if (block_size == 0) break;

                if (!block.isFree()) {
                    // Owner is a tagged data pointer
                    block.owner = fixupSlotValue(&fixup, block.owner);
                }

                current += block_size;
            }
        }
    }

    // Fix return addresses in live callstacks after code compaction
    // (only needed when code blocks moved)
    if (compact_code_heap) {
        for (gc.vm.active_contexts.items) |ctx| {
            fixupCallstackReturnAddresses(gc, ctx, &fixup);
        }

        {
            const ctx = gc.vm.vm_asm.ctx;
            if (!ctx.isActive()) {
                fixupCallstackReturnAddresses(gc, ctx, &fixup);
            }
        }

        // Update code roots after code compaction (inline cache call sites)
        if (code_marks) |marks| {
            updateCodeRootsForCompaction(gc, marks);
        }

        // Update callback stubs after code compaction
        if (gc.vm.callbacks) |callback_heap| {
            if (callback_heap.segment) |seg| {
                var current = seg.start;
                while (current < seg.end) {
                    const block: *code_blocks.CodeBlock = @ptrFromInt(current);
                    const block_size = block.size();
                    if (block_size == 0) break;

                    if (!block.isFree()) {
                        callback_heap.update(block, gc.vm);
                    }

                    current += block_size;
                }
            }
        }
    }

    // Rebuild code block index and clear remembered sets
    if (gc.vm.code) |code| {
        if (compact_code_heap) {
            code.initializeAllBlocksSet() catch @panic("OOM");
            // scan_literals/scan_code_ptrs are indexed by block address.
            // After code compaction they must be rebuilt for the new layout.
            code.rebuildScanFlags(gc.allocator);
        }
        code.clearRememberedSets();
    }

    // Clear cards/decks after compaction
    sweep_mod.resetTenuredCards(gc);

    // Flush instruction cache after code compaction.
    // Data-only compaction flushes only blocks whose instruction operands changed.
    if (compact_code_heap) {
        if (gc.vm.code) |code| {
            icache.flushICache(code.code_start, code.code_size);
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const fixture = @import("gc_test_fixture.zig");
const testing = std.testing;

test "compaction slides live objects down and fixes slots, roots and the data stack" {
    var f: fixture.Fixture = undefined;
    try f.init();
    defer f.deinit();

    const tenured = f.tenured();
    const a = f.tenuredArray(2, layouts.tagFixnum(10));
    const b = f.tenuredArray(6, layouts.tagFixnum(20)); // garbage
    const c = f.tenuredArray(3, layouts.tagFixnum(30));
    const d = f.tenuredArray(4, layouts.tagFixnum(40)); // garbage
    const e = f.tenuredArray(2, layouts.tagFixnum(50));

    // e -> a -> c ; root is e (data root + data stack).
    fixture.arrayAt(e).data()[0] = a;
    fixture.arrayAt(a).data()[0] = c;
    var root: Cell = e;
    try f.vm.data_roots.append(f.vm.allocator, &root);
    defer _ = f.vm.data_roots.pop();
    f.vm.push(layouts.tagFixnum(1));
    f.vm.push(e);

    try testing.expectEqual(tenured.start, layouts.UNTAG(a));
    f.gc.collectFull(true);

    const size_a = fixture.arraySize(2);
    const size_c = fixture.arraySize(3);
    const size_e = fixture.arraySize(2);

    // a stays put, c and e slide down over the holes.
    const new_e = root;
    try testing.expect(new_e != e);
    try testing.expectEqual(layouts.TAG(e), layouts.TAG(new_e));
    try testing.expectEqual(tenured.start + size_a + size_c, layouts.UNTAG(new_e));
    const new_a = fixture.arrayAt(new_e).data()[0];
    try testing.expectEqual(a, new_a);
    const new_c = fixture.arrayAt(new_a).data()[0];
    try testing.expectEqual(tenured.start + size_a, layouts.UNTAG(new_c));
    try testing.expect(layouts.UNTAG(new_c) < layouts.UNTAG(c));

    // Data stack was rewritten too, and untouched entries kept.
    try testing.expectEqual(new_e, f.vm.pop());
    try testing.expectEqual(layouts.tagFixnum(1), f.vm.pop());

    // Payloads survived the move.
    try testing.expectEqual(layouts.tagFixnum(10), fixture.arrayAt(new_a).data()[1]);
    try testing.expectEqual(layouts.tagFixnum(30), fixture.arrayAt(new_c).data()[0]);
    try testing.expectEqual(layouts.tagFixnum(30), fixture.arrayAt(new_c).data()[2]);
    try testing.expectEqual(layouts.tagFixnum(50), fixture.arrayAt(new_e).data()[1]);
    try testing.expectEqual(@as(Cell, 3), fixture.arrayAt(new_c).getCapacity());

    // Free list is a single trailing block covering everything after e.
    const live = size_a + size_c + size_e;
    try testing.expectEqual(@as(Cell, 1), tenured.free_list.freeBlockCount());
    try testing.expectEqual(tenured.size - live, tenured.freeBytes());
    try testing.expectEqual(tenured.size - live, tenured.free_list.largestFreeBlock());
    const next = f.heap.allocateTenured(16) orelse return error.TestUnexpectedResult;
    try testing.expect(next >= tenured.start + live and next < tenured.end);

    try testing.expectEqual(@as(Cell, 1), f.heap.full_collections);
    _ = b;
    _ = d;
}

test "compaction resolves tuple sizes through a moved layout and fixes the layout slot" {
    var f: fixture.Fixture = undefined;
    try f.init();
    defer f.deinit();

    const tenured = f.tenured();
    _ = f.tenuredArray(5, layouts.false_object); // garbage, forces the layout to move
    const layout = f.tenuredTupleLayout(3);
    const tuple = f.tenuredTuple(layout, layouts.false_object);
    _ = f.tenuredArray(2, layouts.false_object); // garbage between tuple and x
    const x = f.tenuredArray(1, layouts.tagFixnum(77));

    const t: *layouts.Tuple = @ptrFromInt(layouts.UNTAG(tuple));
    t.data()[0] = layouts.tagFixnum(7);
    t.data()[1] = x;
    f.vm.push(tuple);

    f.gc.collectFull(true);

    const new_tuple = f.vm.peek();
    try testing.expectEqual(layouts.TAG(tuple), layouts.TAG(new_tuple));
    try testing.expectEqual(tenured.start + fixture.tuple_layout_size, layouts.UNTAG(new_tuple));

    const nt: *layouts.Tuple = @ptrFromInt(layouts.UNTAG(new_tuple));
    // Layout slot points at the relocated layout, which now sits at the start.
    try testing.expectEqual(tenured.start | fixture.array_tag, nt.layout);
    const nl: *layouts.TupleLayout = @ptrFromInt(layouts.UNTAG(nt.layout));
    try testing.expectEqual(layouts.tagFixnum(3), nl.size);
    try testing.expectEqual(layouts.tagFixnum(@intCast(fixture.tuple_layout_capacity)), nl.capacity);

    // All three slots were carried along and fixed up.
    try testing.expectEqual(layouts.tagFixnum(7), nt.data()[0]);
    const new_x = nt.data()[1];
    try testing.expectEqual(tenured.start + fixture.tuple_layout_size + fixture.tupleSize(3), layouts.UNTAG(new_x));
    try testing.expectEqual(layouts.tagFixnum(77), fixture.arrayAt(new_x).data()[0]);
    try testing.expectEqual(layouts.false_object, nt.data()[2]);

    const live = fixture.tuple_layout_size + fixture.tupleSize(3) + fixture.arraySize(1);
    try testing.expectEqual(tenured.size - live, tenured.freeBytes());
}

test "compaction moves pointer-free objects and preserves their bytes" {
    var f: fixture.Fixture = undefined;
    try f.init();
    defer f.deinit();

    const tenured = f.tenured();
    _ = f.tenuredArray(9, layouts.false_object); // garbage hole

    var pattern: [300]u8 = undefined;
    for (&pattern, 0..) |*p, i| p.* = @truncate(i * 7 + 3);
    const ba = f.tenuredByteArray(&pattern);
    _ = f.tenuredArray(1, layouts.false_object); // garbage hole
    const text = "hello, compaction";
    const str = f.tenuredString(text);
    const holder = f.tenuredArray(2, layouts.false_object);
    fixture.arrayAt(holder).data()[0] = ba;
    fixture.arrayAt(holder).data()[1] = str;
    f.vm.push(holder);

    f.gc.collectFull(true);

    const h = fixture.arrayAt(f.vm.peek());
    const new_ba = h.data()[0];
    const new_str = h.data()[1];
    try testing.expect(new_ba != ba);
    try testing.expect(new_str != str);
    try testing.expectEqual(tenured.start, layouts.UNTAG(new_ba));
    try testing.expectEqual(tenured.start + fixture.byteArraySize(pattern.len), layouts.UNTAG(new_str));

    const nba: *layouts.ByteArray = @ptrFromInt(layouts.UNTAG(new_ba));
    try testing.expectEqual(layouts.tagFixnum(pattern.len), nba.capacity);
    try testing.expectEqualSlices(u8, &pattern, nba.data()[0..pattern.len]);

    const ns: *layouts.String = @ptrFromInt(layouts.UNTAG(new_str));
    try testing.expectEqual(layouts.tagFixnum(text.len), ns.length);
    try testing.expectEqual(layouts.false_object, ns.aux);
    try testing.expectEqual(layouts.tagFixnum(0), ns.hashcode_field);
    try testing.expectEqualSlices(u8, text, ns.data()[0..text.len]);
}

test "compaction fixes every slot of an object spanning several cards" {
    var f: fixture.Fixture = undefined;
    try f.init();
    defer f.deinit();

    const tenured = f.tenured();
    _ = f.tenuredArray(1, layouts.false_object); // garbage hole
    const cap: Cell = 200; // 1616 bytes: covers > 6 cards of 256 bytes
    const big = f.tenuredArray(cap, layouts.false_object);
    var targets: [8]Cell = undefined;
    for (&targets, 0..) |*t, i| {
        _ = f.tenuredArray(1, layouts.false_object); // garbage before each target
        t.* = f.tenuredArray(1, layouts.tagFixnum(@intCast(i)));
    }
    // Spread references across the big array, one per card-ish stride.
    for (targets, 0..) |t, i| fixture.arrayAt(big).data()[i * 27] = t;
    fixture.arrayAt(big).data()[cap - 1] = big; // self reference
    f.vm.push(big);

    f.gc.collectFull(true);

    const new_big = f.vm.peek();
    try testing.expectEqual(tenured.start, layouts.UNTAG(new_big));
    const nb = fixture.arrayAt(new_big);
    try testing.expectEqual(cap, nb.getCapacity());
    var expected_addr = tenured.start + fixture.arraySize(cap);
    for (0..targets.len) |i| {
        const slot = nb.data()[i * 27];
        try testing.expectEqual(expected_addr | fixture.array_tag, slot);
        try testing.expectEqual(layouts.tagFixnum(@intCast(i)), fixture.arrayAt(slot).data()[0]);
        expected_addr += fixture.arraySize(1);
    }
    try testing.expectEqual(new_big, nb.data()[cap - 1]);
    // Untouched cells are still f.
    try testing.expectEqual(layouts.false_object, nb.data()[1]);
    try testing.expectEqual(layouts.false_object, nb.data()[cap - 2]);
    try testing.expectEqual(tenured.size - (fixture.arraySize(cap) + targets.len * fixture.arraySize(1)), tenured.freeBytes());
}

test "full compacting collection promotes nursery objects and then compacts them" {
    var f: fixture.Fixture = undefined;
    try f.init();
    defer f.deinit();

    const tenured = f.tenured();
    _ = f.tenuredArray(3, layouts.false_object); // garbage hole at the start
    const t = f.tenuredArray(1, layouts.tagFixnum(5));
    const n = f.nurseryArray(1, t);
    const nursery_start = f.heap.nursery.start;
    try testing.expect(f.inNursery(n));
    f.vm.push(n);

    f.gc.collectFull(true);

    const new_n = f.vm.peek();
    try testing.expect(f.inTenured(new_n));
    // t was first in tenured after the hole, so it slides to the start; the
    // promoted copy of n lands right behind it.
    try testing.expectEqual(tenured.start | fixture.array_tag, fixture.arrayAt(new_n).data()[0]);
    try testing.expectEqual(tenured.start + fixture.arraySize(1), layouts.UNTAG(new_n));
    try testing.expectEqual(layouts.tagFixnum(5), fixture.arrayAt(fixture.arrayAt(new_n).data()[0]).data()[0]);

    // The nursery original became a forwarding pointer and the nursery was reset.
    try testing.expect(fixture.objectAt(n).isForwardingPointer());
    try testing.expectEqual(nursery_start, f.vm.vm_asm.nursery.here);
    try testing.expectEqual(nursery_start, f.heap.nursery.here);
    try testing.expectEqual(tenured.size - 2 * fixture.arraySize(1), tenured.freeBytes());
}

test "compaction with nothing live empties tenured space" {
    var f: fixture.Fixture = undefined;
    try f.init();
    defer f.deinit();

    const tenured = f.tenured();
    _ = f.tenuredArray(1, layouts.false_object);
    _ = f.tenuredByteArray("bytes");
    _ = f.tenuredArray(300, layouts.false_object);

    f.gc.collectFull(true);

    try testing.expectEqual(tenured.size, tenured.freeBytes());
    try testing.expectEqual(@as(Cell, 1), tenured.free_list.freeBlockCount());
    try testing.expectEqual(tenured.size, tenured.free_list.largestFreeBlock());
    const reused = f.heap.allocateTenured(32) orelse return error.TestUnexpectedResult;
    try testing.expect(tenured.contains(reused));
}

test "compaction with no holes leaves objects in place" {
    var f: fixture.Fixture = undefined;
    try f.init();
    defer f.deinit();

    const tenured = f.tenured();
    const a = f.tenuredArray(2, layouts.false_object);
    const b = f.tenuredArray(4, layouts.tagFixnum(4));
    fixture.arrayAt(a).data()[0] = b;
    fixture.arrayAt(a).data()[1] = a;
    f.vm.push(a);

    f.gc.collectFull(true);

    try testing.expectEqual(a, f.vm.peek());
    try testing.expectEqual(b, fixture.arrayAt(a).data()[0]);
    try testing.expectEqual(a, fixture.arrayAt(a).data()[1]);
    try testing.expectEqual(layouts.tagFixnum(4), fixture.arrayAt(b).data()[3]);
    try testing.expectEqual(tenured.size - fixture.arraySize(2) - fixture.arraySize(4), tenured.freeBytes());
    try testing.expectEqual(@as(Cell, 1), tenured.free_list.freeBlockCount());
}

test "compaction fixes special objects, retain stack and context objects" {
    var f: fixture.Fixture = undefined;
    try f.init();
    defer f.deinit();

    const tenured = f.tenured();
    _ = f.tenuredArray(7, layouts.false_object); // garbage hole
    const via_special = f.tenuredArray(1, layouts.tagFixnum(1));
    const via_retain = f.tenuredArray(1, layouts.tagFixnum(2));
    const via_context_object = f.tenuredArray(1, layouts.tagFixnum(3));
    const via_spare = f.tenuredArray(1, layouts.tagFixnum(4));

    f.vm.vm_asm.special_objects[2] = via_special;
    f.vm.vm_asm.ctx.pushRetain(via_retain);
    f.vm.vm_asm.ctx.context_objects[1] = via_context_object;
    f.vm.vm_asm.spare_ctx.push(via_spare);

    f.gc.collectFull(true);

    const s = fixture.arraySize(1);
    const new_special = f.vm.vm_asm.special_objects[2];
    const new_retain = f.vm.vm_asm.ctx.peekRetain();
    const new_context_object = f.vm.vm_asm.ctx.context_objects[1];
    const new_spare = f.vm.vm_asm.spare_ctx.peek();

    try testing.expectEqual(tenured.start, layouts.UNTAG(new_special));
    try testing.expectEqual(tenured.start + s, layouts.UNTAG(new_retain));
    try testing.expectEqual(tenured.start + 2 * s, layouts.UNTAG(new_context_object));
    try testing.expectEqual(tenured.start + 3 * s, layouts.UNTAG(new_spare));
    try testing.expectEqual(layouts.tagFixnum(1), fixture.arrayAt(new_special).data()[0]);
    try testing.expectEqual(layouts.tagFixnum(2), fixture.arrayAt(new_retain).data()[0]);
    try testing.expectEqual(layouts.tagFixnum(3), fixture.arrayAt(new_context_object).data()[0]);
    try testing.expectEqual(layouts.tagFixnum(4), fixture.arrayAt(new_spare).data()[0]);
}

test "compaction clears the tenured card table" {
    var f: fixture.Fixture = undefined;
    try f.init();
    defer f.deinit();

    _ = f.tenuredArray(1, layouts.false_object); // garbage hole
    const a = f.tenuredArray(2, layouts.false_object);
    const slot = &fixture.arrayAt(a).data()[0];
    f.vm.push(a);
    f.vm.writeBarrier(slot);
    try testing.expect(f.cardByte(slot) != 0);

    f.gc.collectFull(true);

    const new_slot = &fixture.arrayAt(f.vm.peek()).data()[0];
    try testing.expectEqual(@as(u8, 0), f.cardByte(slot));
    try testing.expectEqual(@as(u8, 0), f.cardByte(new_slot));
}

test "compactPhase forwards data through the mark bits without moving unmarked space" {
    var f: fixture.Fixture = undefined;
    try f.init();
    defer f.deinit();

    const tenured = f.tenured();
    const g = f.tenuredArray(2, layouts.false_object); // garbage
    const a = f.tenuredArray(2, layouts.tagFixnum(9));
    f.vm.push(a);

    // Drive the phases by hand instead of through collectFull.
    f.fullMark();
    sweep_mod.sweepPhase(&f.gc);
    try testing.expectEqual(@as(Cell, 2), tenured.free_list.freeBlockCount());

    compactPhase(&f.gc, true);

    try testing.expectEqual(layouts.UNTAG(g) | fixture.array_tag, f.vm.peek());
    try testing.expectEqual(layouts.tagFixnum(9), fixture.arrayAt(f.vm.peek()).data()[1]);
    try testing.expectEqual(@as(Cell, 1), tenured.free_list.freeBlockCount());
    try testing.expectEqual(tenured.size - fixture.arraySize(2), tenured.freeBytes());
    // The mark bit for the old location is stale but the OSM knows the new one.
    const card0 = (layouts.UNTAG(g) - tenured.start) / vm_mod.card_size;
    try testing.expectEqual(tenured.start, tenured.object_start.findObjectContainingCard(card0 + 1) orelse 0);
}
