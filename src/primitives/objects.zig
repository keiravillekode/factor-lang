// primitives/objects.zig - Object creation, slot access, arrays, strings, words

const std = @import("std");
const bignum = @import("../bignum.zig");
const code_blocks = @import("../code_blocks.zig");
const layouts = @import("../layouts.zig");
const math = @import("../fixnum.zig");
const objects = @import("../objects.zig");
const slot_visitor = @import("../slot_visitor.zig");
const jit_protect = @import("../jit_protect.zig");
const vm_mod = @import("../vm.zig");
const diagnostics = @import("diagnostics.zig");

const Cell = layouts.Cell;
const CodeBlock = code_blocks.CodeBlock;
const Fixnum = layouts.Fixnum;
const FactorVM = vm_mod.FactorVM;
const VMAssemblyFields = vm_mod.VMAssemblyFields;

const array_size_max: Cell = @as(Cell, 1) << (64 - layouts.tag_bits - 2);

// Validate and unbox an array size from a cell value.
// For bignums that don't fit in fixnum, throws out_of_fixnum_range.
// For values out of array size range, throws array_size.
fn unboxArraySize(vm: *FactorVM, obj: Cell) ?Cell {
    var n: Fixnum = undefined;

    const tag = layouts.typeTag(obj);
    switch (tag) {
        .fixnum => {
            n = layouts.untagFixnum(obj);
        },
        .bignum => {
            // Try to convert bignum to fixnum
            const bn: *const bignum.Bignum = @ptrFromInt(layouts.UNTAG(obj));
            if (!bignum.fitsFixnum(bn)) {
                // Bignum too large for fixnum - throw out_of_fixnum_range
                vm.fixnumRangeError(obj);
            }
            n = bignum.toFixnum(bn);
        },
        else => vm.fixnumRangeError(obj),
    }

    // Check array size bounds
    if (n >= 0 and @as(Cell, @intCast(n)) < array_size_max) {
        return @intCast(n);
    }
    vm.generalError(.array_size, obj, layouts.tagFixnum(@intCast(array_size_max)));
}

// --- Object Primitives ---

pub export fn primitive_clone(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    var obj = vm.peek();
    const tag = layouts.typeTag(obj);

    if (tag == .fixnum or obj == layouts.false_object) {
        return;
    }

    if (tag == .tuple) {
        const tuple: *const layouts.Tuple = @ptrFromInt(layouts.UNTAG(obj));
        std.debug.assert(tuple.header != tuple.layout);
        std.debug.assert(layouts.hasTag(tuple.layout, .array));
    }

    // Root the object - allocation can trigger GC which may move it
    vm.data_roots.appendAssumeCapacity(&obj);
    defer _ = vm.data_roots.pop();

    // Compute object size
    const size = slot_visitor.objectSize(layouts.UNTAG(obj));
    if (size == 0) return;

    // Allocate via the general path so objects larger than the nursery are
    // placed directly in tenured space (allotObject -> allotLargeObject).
    // The previous nursery-only path raised a spurious "memory error" whenever
    // the clone exceeded the nursery (e.g. large hash-sets in benchmark.hash-sets).
    const tagged_dst = vm.allotObject(tag, size) orelse vm.memoryError();
    const dst_addr = layouts.UNTAG(tagged_dst);

    // After potential GC, re-derive source pointer from rooted obj
    const src_ptr: [*]const u8 = @ptrFromInt(layouts.UNTAG(obj));
    const dst_ptr: [*]u8 = @ptrFromInt(dst_addr);

    // Copy entire object (overwrites the freshly-set header with the source's)
    @memcpy(dst_ptr[0..size], src_ptr[0..size]);

    // Reset hashcode (bits 6+ of header), keeping free/forwarding/tag bits
    const dst_obj: *layouts.Object = @ptrFromInt(dst_addr);
    dst_obj.header = dst_obj.header & 0x3F;

    vm.replace(tagged_dst);
}

pub export fn primitive_wrapper(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    // ( obj -- wrapper )
    const tagged = vm.allotObject(.wrapper, @sizeOf(layouts.Wrapper)) orelse vm.memoryError();

    // Peek AFTER allotObject (which may trigger GC and move stack values)
    const obj = vm.peek();

    const wrapper: *layouts.Wrapper = @ptrFromInt(layouts.UNTAG(tagged));
    wrapper.object = obj;
    vm.replace(tagged);
}

// --- Slot Access ---

pub export fn primitive_slot(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const ctx = vm_asm.ctx;
    // ( obj n -- value )
    const n = layouts.untagFixnum(ctx.pop());
    const obj = ctx.pop();
    const obj_ptr: *const layouts.Object = @ptrFromInt(layouts.UNTAG(obj));
    const slots = obj_ptr.slots();
    const value = slots[@intCast(n)];

    ctx.push(value);
}

pub export fn primitive_set_slot(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    const ctx = vm_asm.ctx;
    // ( value obj n -- )
    const n = layouts.untagFixnum(ctx.pop());
    const obj = ctx.pop();
    const value = ctx.pop();
    const obj_ptr: *layouts.Object = @ptrFromInt(layouts.UNTAG(obj));
    const slots = obj_ptr.slots();
    const slot_ptr = &slots[@intCast(n)];
    slot_ptr.* = value;
    vm.writeBarrierKnownHeapWithValue(slot_ptr, value);
}

// --- Tuple Allocation ---

pub export fn primitive_tuple(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    // ( layout -- tuple )
    // Use peek/replace pattern for GC safety - layout stays on stack during potential GC
    var layout_cell = vm.peek();

    // NOTE: tuple_layout objects have tag ARRAY (2), not TUPLE (7)!
    // This is because in Factor, tuple_layout extends array.
    vm.checkTag(layout_cell, .array);

    var layout: *const layouts.TupleLayout = @ptrFromInt(layouts.UNTAG(layout_cell));
    const num_slots = layouts.untagFixnumUnsigned(layout.size);
    const tuple_size = @sizeOf(layouts.Tuple) + num_slots * @sizeOf(Cell);

    // Allocate tuple (may trigger GC)
    const tagged = vm.allotObject(.tuple, tuple_size) orelse vm.memoryError();

    // Re-read layout from stack in case GC moved it
    layout_cell = vm.peek();
    layout = @ptrFromInt(layouts.UNTAG(layout_cell));

    const tuple: *layouts.Tuple = @ptrFromInt(layouts.UNTAG(tagged));
    tuple.layout = layout_cell;

    // Fill slots with f (false_object)
    @memset(tuple.data()[0..num_slots], layouts.false_object);

    std.debug.assert(tuple.header == (@as(Cell, @intFromEnum(layouts.TypeTag.tuple)) << 2));
    std.debug.assert(tuple.layout == layout_cell);

    vm.replace(tagged);
}

pub export fn primitive_tuple_boa(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    const ctx = vm_asm.ctx;
    // ( slot-values... layout -- tuple )
    // Create a new tuple filling slots from the stack (BOA = By Order of Arguments)
    // Pop the layout and root it locally so we can bulk-copy the remaining
    // stack cells.
    var layout_cell = ctx.pop();

    // NOTE: tuple_layout objects have tag ARRAY (2), not TUPLE (7)!
    vm.checkTag(layout_cell, .array);

    vm.data_roots.appendAssumeCapacity(&layout_cell);
    defer _ = vm.data_roots.pop();

    const layout: *const layouts.TupleLayout = @ptrFromInt(layouts.UNTAG(layout_cell));
    const num_slots = layouts.untagFixnumUnsigned(layout.size);
    const tuple_size = @sizeOf(layouts.Tuple) + num_slots * @sizeOf(Cell);
    const slot_size = num_slots * @sizeOf(Cell);

    // Allocate tuple (may trigger GC which may move stack values)
    const tagged = vm.allotObject(.tuple, tuple_size) orelse {
        ctx.datastack -= slot_size;
        vm.memoryError();
    };

    const tuple: *layouts.Tuple = @ptrFromInt(layouts.UNTAG(tagged));
    tuple.layout = layout_cell;

    if (slot_size > 0) {
        const src_base = ctx.datastack - slot_size + @sizeOf(Cell);
        const src_data: [*]const Cell = @ptrFromInt(src_base);
        @memcpy(tuple.data()[0..num_slots], src_data[0..num_slots]);
    }

    // Pop slot values from stack. The layout was already popped above.
    ctx.datastack -= slot_size;

    std.debug.assert(tuple.header == (@as(Cell, @intFromEnum(layouts.TypeTag.tuple)) << 2));
    std.debug.assert(layouts.hasTag(tuple.layout, .array));

    vm.push(tagged);
}

// --- Identity/Hash ---

pub export fn primitive_identity_hashcode(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const ctx = vm_asm.ctx;
    // ( obj -- hashcode )
    const obj = ctx.peek();
    if (layouts.isImmediate(obj)) {
        // Immediates - leave unchanged (value is its own hashcode)
        // But fixnums need to stay as-is
        return;
    }
    const obj_ptr: *const layouts.Object = @ptrFromInt(layouts.UNTAG(obj));
    const hc = obj_ptr.hashcode();
    ctx.replace(layouts.tagFixnum(@intCast(hc)));
}

pub export fn primitive_compute_identity_hashcode(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    const ctx = vm_asm.ctx;
    // ( obj -- )
    // Compute and set identity hashcode (pops the object!)
    const obj = ctx.pop();
    if (!layouts.isImmediate(obj)) {
        const obj_addr = layouts.UNTAG(obj);
        const obj_ptr: *layouts.Object = @ptrFromInt(obj_addr);

        vm.object_counter += 1;
        if (vm.object_counter == 0) vm.object_counter += 1; // Avoid 0
        obj_ptr.setHashcode(obj_addr ^ vm.object_counter);
    }
}

pub export fn primitive_become(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    // ( old-array new-array -- )
    // This is used by tools.deploy.shaker and tuple reshaping

    // Trigger minor GC first to ensure consistency
    diagnostics.primitive_minor_gc(vm_asm);

    // Pop arrays from stack
    const new_array = vm.pop();
    const old_array = vm.pop();

    // Type check: both must be arrays
    if (!layouts.hasTag(old_array, .array) or
        !layouts.hasTag(new_array, .array))
    {
        vm.criticalError("become: arguments must be arrays", 0);
        return;
    }

    const old_arr: *const layouts.Array = @ptrFromInt(layouts.UNTAG(old_array));
    const new_arr: *const layouts.Array = @ptrFromInt(layouts.UNTAG(new_array));

    const capacity = old_arr.getCapacity();

    // Arrays must have same capacity
    if (capacity != new_arr.getCapacity()) {
        vm.criticalError("become: arrays must have same capacity", 0);
        return;
    }

    const BecomeMap = std.AutoHashMap(Cell, Cell);
    var become_map = BecomeMap.init(vm.allocator);
    defer become_map.deinit();

    const old_data = old_arr.data();
    const new_data = new_arr.data();

    for (0..capacity) |i| {
        const old_ptr = old_data[i];
        const new_ptr = new_data[i];
        if (old_ptr != new_ptr) {
            // Map the untagged addresses
            const old_untagged = layouts.UNTAG(old_ptr);
            become_map.put(old_untagged, new_ptr) catch {
                vm.criticalError("become: failed to build forwarding map", 0);
                return;
            };
        }
    }

    // Fixup for become: substitutes old references with new ones via the become map.
    const BecomeFixup = struct {
        map: *BecomeMap,

        pub fn visitSlot(self: *@This(), slot: *Cell) void {
            const value = slot.*;
            if (!layouts.isImmediate(value)) {
                const untagged = layouts.UNTAG(value);
                if (self.map.get(untagged)) |new_value| {
                    slot.* = new_value;
                }
            }
        }
    };

    var become_fixup = BecomeFixup{ .map = &become_map };

    // Visit all roots
    // 1. Special objects
    for (&vm.vm_asm.special_objects) |*slot| {
        become_fixup.visitSlot(slot);
    }

    // 2. Data stack
    {
        const ctx = vm.vm_asm.ctx;
        if (ctx.datastack_seg) |seg| {
            var ptr = seg.start;
            while (ptr <= ctx.datastack) {
                const slot: *Cell = @ptrFromInt(ptr);
                become_fixup.visitSlot(slot);
                ptr += @sizeOf(Cell);
            }
        }

        // 3. Retain stack
        if (ctx.retainstack_seg) |seg| {
            var ptr = seg.start;
            while (ptr <= ctx.retainstack) {
                const slot: *Cell = @ptrFromInt(ptr);
                become_fixup.visitSlot(slot);
                ptr += @sizeOf(Cell);
            }
        }

        // 4. Context objects
        for (&ctx.context_objects) |*slot| {
            become_fixup.visitSlot(slot);
        }

        // 4b. Native callstack spill slots. C++ become reaches these via
        // visit_all_roots(); without them an object live only in a spilled
        // register (not on the data/retain stacks) would not be remapped.
        // The callstack pointers were saved by the minor GC at the top of
        // become, so ctx.callstack_top/bottom are valid here.
        if (vm.code) |code| {
            slot_visitor.visitLiveCallstackRoots(BecomeFixup, &become_fixup, code, ctx.callstack_top, ctx.callstack_bottom);
        }
    }

    // 5. Data roots
    for (vm.data_roots.items) |root| {
        become_fixup.visitSlot(root);
    }

    // 6. Callback stubs (owners are GC roots)
    if (vm.callbacks) |callback_heap| {
        const Ctx = struct {
            fixup: *BecomeFixup,
            fn visit(slot: *Cell, c: @This()) void {
                c.fixup.visitSlot(slot);
            }
        };
        const ctx = Ctx{ .fixup = &become_fixup };
        callback_heap.iterateOwnersWithCtx(Ctx, Ctx.visit, ctx);
    }

    // 7. Uninitialized code blocks (literal arrays are roots)
    if (vm.code) |code| {
        var iter = code.uninitialized_blocks.iterator();
        while (iter.next()) |entry| {
            become_fixup.visitSlot(entry.value_ptr);
        }
    }

    // 8. Active contexts
    for (vm.active_contexts.items) |ctx| {

        // Visit context stacks
        if (ctx.datastack_seg) |seg| {
            var ptr = seg.start;
            while (ptr <= ctx.datastack) {
                const slot: *Cell = @ptrFromInt(ptr);
                become_fixup.visitSlot(slot);
                ptr += @sizeOf(Cell);
            }
        }

        if (ctx.retainstack_seg) |seg| {
            var ptr = seg.start;
            while (ptr <= ctx.retainstack) {
                const slot: *Cell = @ptrFromInt(ptr);
                become_fixup.visitSlot(slot);
                ptr += @sizeOf(Cell);
            }
        }

        // Visit context objects
        for (&ctx.context_objects) |*slot| {
            become_fixup.visitSlot(slot);
        }

        // Native callstack spill slots for this context (see 4b above).
        if (vm.code) |code| {
            slot_visitor.visitLiveCallstackRoots(BecomeFixup, &become_fixup, code, ctx.callstack_top, ctx.callstack_bottom);
        }
    }

    // Visit all objects in the heap (tenured + aging). Nursery should be empty
    // after the minor GC above.
    if (vm.gc) |gc| {
        const data_heap = gc.heap;
        const was_gc_off = vm.gc_off;
        vm.gc_off = true;
        defer vm.gc_off = was_gc_off;

        // Aging space
        var aging_iter = slot_visitor.ObjectIterator.init(data_heap.aging.start, data_heap.aging.here);
        while (aging_iter.next()) |addr| {
            _ = slot_visitor.visitDataObjectSlots(BecomeFixup, &become_fixup, addr);
        }

        // Tenured space
        var tenured_iter = slot_visitor.ObjectIterator.init(data_heap.tenured.start, data_heap.tenured.end);
        while (tenured_iter.next()) |addr| {
            _ = slot_visitor.visitDataObjectSlots(BecomeFixup, &become_fixup, addr);
        }
    }

    // Visit all code blocks and update embedded literals
    if (vm.code) |code| {
        // op.storeValue and the block-header visitSlot writes below mutate
        // executable MAP_JIT memory. On Apple Silicon (W^X) that write faults
        // (SIGBUS) unless the page is made writable first; the fault is not
        // resumable, so the handler loops forever re-executing the store. Open
        // a W^X writable scope for the duration (matches gc()'s jit_protect.Scope).
        var jit_scope = jit_protect.Scope.init();
        defer jit_scope.deinit();

        code.flushPending();
        for (code.all_blocks_sorted.items) |addr| {
            const block: *CodeBlock = @ptrFromInt(addr);
            if (block.isFree()) continue;

            // Update header pointers
            become_fixup.visitSlot(@ptrCast(&block.owner));
            become_fixup.visitSlot(@ptrCast(&block.parameters));
            become_fixup.visitSlot(@ptrCast(&block.relocation));

            // Update embedded literals (skip uninitialized blocks)
            if (!code.isUninitializedAddress(addr)) {
                if (block.relocation != layouts.false_object and
                    layouts.hasTag(block.relocation, .byte_array))
                {
                    const reloc_ba: *const layouts.ByteArray = @ptrFromInt(layouts.UNTAG(block.relocation));
                    const reloc_cap = layouts.untagFixnumUnsigned(reloc_ba.capacity);
                    if (reloc_cap > 0) {
                        const reloc_data = reloc_ba.data();
                        const reloc_count = reloc_cap / @sizeOf(code_blocks.RelocationEntry);
                        var param_index: Cell = 0;
                        var modified = false;
                        for (0..reloc_count) |i| {
                            const entry_ptr: *const code_blocks.RelocationEntry =
                                @ptrCast(@alignCast(reloc_data + i * @sizeOf(code_blocks.RelocationEntry)));
                            if (entry_ptr.getType() == .literal) {
                                var op = code_blocks.InstructionOperand.init(entry_ptr.*, block, param_index);
                                const value = op.loadValue();
                                const value_unsigned: Cell = @bitCast(value);
                                if (!layouts.isImmediate(value_unsigned)) {
                                    const untagged = layouts.UNTAG(value_unsigned);
                                    if (become_map.get(untagged)) |new_value| {
                                        op.storeValue(@bitCast(new_value));
                                        modified = true;
                                    }
                                }
                            }
                            param_index += entry_ptr.numberOfParameters();
                        }
                        if (modified) {
                            block.flushIcache();
                        }
                    }
                }
            }

            // Add to remembered set (may have introduced old->young refs)
            code.writeBarrier(block) catch @panic("OOM");
        }
    }

    // Mark all cards dirty since we may have introduced old->new references
    vm.markAllCards();
}

// --- Array Primitives ---

pub export fn primitive_array(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    // ( capacity fill -- array )
    var fill = vm.pop();
    const capacity_cell = vm.pop();

    const capacity = unboxArraySize(vm, capacity_cell) orelse return;

    // Only root fill if it's a heap object — immediates (fixnums, f) can't be
    // moved by GC, so skip the root push/pop overhead for the common case.
    const needs_root = !layouts.isImmediate(fill);
    if (needs_root) vm.data_roots.appendAssumeCapacity(&fill);
    defer if (needs_root) {
        _ = vm.data_roots.pop();
    };

    vm.push(vm.allotArray(capacity, fill) orelse vm.memoryError());
}

pub export fn primitive_resize_array(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    // ( capacity array -- new-array )
    const arr = vm.pop();
    const capacity_cell = vm.pop();

    const new_capacity = unboxArraySize(vm, capacity_cell) orelse return;

    if (!layouts.hasTag(arr, .array)) {
        vm.push(layouts.false_object);
        return;
    }

    // reallotArray handles GC rooting internally
    if (vm.reallotArray(arr, new_capacity)) |new_arr| {
        vm.push(new_arr);
    } else {
        vm.push(layouts.false_object);
    }
}

// --- Byte Array Primitives ---

pub export fn primitive_byte_array(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    // ( size -- byte-array )
    const size_cell = vm.pop();
    const size = unboxArraySize(vm, size_cell) orelse return;

    const result = vm.allotByteArray(size);
    vm.push(result);
}

pub export fn primitive_uninitialized_byte_array(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    // ( size -- byte-array )
    const size_cell = vm.pop();
    const size = unboxArraySize(vm, size_cell) orelse return;

    vm.push(vm.allotUninitializedByteArray(size));
}

pub export fn primitive_resize_byte_array(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    // ( n byte-array -- new-byte-array )
    var ba_cell = vm.pop();
    const size_cell = vm.pop();

    if (!layouts.hasTag(ba_cell, .byte_array)) {
        vm.push(layouts.false_object);
        return;
    }
    const new_size = unboxArraySize(vm, size_cell) orelse return;

    const old_ba: *const layouts.ByteArray = @ptrFromInt(layouts.UNTAG(ba_cell));
    const old_size = layouts.untagFixnumUnsigned(old_ba.capacity);

    if (new_size == old_size) {
        vm.push(ba_cell);
        return;
    }

    if (new_size <= old_size and vm.vm_asm.nursery.contains(@ptrFromInt(layouts.UNTAG(ba_cell)))) {
        const ba_mut: *layouts.ByteArray = @ptrFromInt(layouts.UNTAG(ba_cell));
        ba_mut.capacity = layouts.tagFixnum(@as(Fixnum, @intCast(new_size)));
        vm.push(ba_cell);
        return;
    }

    // Root old byte array - allocation can trigger GC
    vm.data_roots.appendAssumeCapacity(&ba_cell);
    defer _ = vm.data_roots.pop();

    // Use allotObject which routes large objects to tenured space
    const tagged = vm.allotUninitializedByteArray(new_size);
    const addr = layouts.UNTAG(tagged);

    const new_ba: *layouts.ByteArray = @ptrFromInt(addr);
    new_ba.capacity = layouts.tagFixnum(@intCast(new_size));

    // Re-derive old pointer from rooted cell (allotObject may trigger GC)
    const old_ba_after_gc: *const layouts.ByteArray = @ptrFromInt(layouts.UNTAG(ba_cell));
    const copy_size = @min(old_size, new_size);
    @memcpy(new_ba.data()[0..copy_size], old_ba_after_gc.data()[0..copy_size]);

    if (new_size > old_size) {
        @memset(new_ba.data()[old_size..new_size], 0);
    }

    vm.push(tagged);
}

// --- String Primitives ---

pub export fn primitive_string(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    // ( length fill -- string )
    const fill_cell = vm.pop();
    const length_cell = vm.pop();

    const length = unboxArraySize(vm, length_cell) orelse return;
    const fill = layouts.untagFixnumUnsigned(fill_cell);

    // Use allotObject which routes large objects to tenured space
    const string_size = layouts.alignCell(@sizeOf(layouts.String) + length, layouts.data_alignment);

    var tagged = vm.allotObject(.string, string_size) orelse vm.memoryError();

    const str: *layouts.String = @ptrFromInt(layouts.UNTAG(tagged));
    str.length = layouts.tagFixnum(@intCast(length));
    str.hashcode_field = layouts.false_object;
    str.aux = layouts.false_object;

    if (fill <= 0x7f) {
        @memset(str.data()[0..length], @truncate(fill));
    } else {
        // Non-ASCII - allocate aux array. Root the string first since
        // the aux allocation can trigger GC which may move the string.
        vm.data_roots.appendAssumeCapacity(&tagged);
        defer _ = vm.data_roots.pop();

        const aux_capacity = length * 2;
        const aux_size = layouts.alignCell(@sizeOf(layouts.ByteArray) + aux_capacity, layouts.data_alignment);
        if (vm.allotObject(.byte_array, aux_size)) |aux_tagged| {
            // Re-derive str pointer - GC may have moved the string
            const str2: *layouts.String = @ptrFromInt(layouts.UNTAG(tagged));
            const aux: *layouts.ByteArray = @ptrFromInt(layouts.UNTAG(aux_tagged));
            aux.capacity = layouts.tagFixnum(@intCast(aux_capacity));
            str2.aux = aux_tagged;
            // The aux allocation above may have promoted the string to aging/
            // tenured; record the old->young pointer so the next minor GC keeps
            // (and updates) aux (matches C++ write_barrier(&str->aux)).
            vm.writeBarrierKnownHeapWithValue(&str2.aux, aux_tagged);

            const lo_fill: u8 = @truncate((fill & 0x7f) | 0x80);
            @memset(str2.data()[0..length], lo_fill);

            const hi_fill: u16 = @truncate((fill >> 7) ^ 0x1);
            const aux_data: [*]u16 = @ptrCast(@alignCast(aux.data()));
            @memset(aux_data[0..length], hi_fill);
        } else {
            const str2: *layouts.String = @ptrFromInt(layouts.UNTAG(tagged));
            @memset(str2.data()[0..length], @truncate(fill & 0x7f));
        }
    }

    vm.push(tagged);
}

pub export fn primitive_resize_string(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    // ( n string -- newstring )
    var str_cell = vm.pop();
    const length_cell = vm.pop();

    if (!layouts.hasTag(str_cell, .string)) {
        vm.typeError(.string, str_cell);
    }

    const new_length = unboxArraySize(vm, length_cell) orelse return;

    var old_str: *const layouts.String = @ptrFromInt(layouts.UNTAG(str_cell));
    const old_length = layouts.untagFixnumUnsigned(old_str.length);

    if (new_length == old_length) {
        vm.push(str_cell);
        return;
    }

    const in_nursery = vm.vm_asm.nursery.contains(@ptrFromInt(layouts.UNTAG(str_cell)));
    const has_aux = old_str.aux != layouts.false_object and layouts.hasTag(old_str.aux, .byte_array);
    const aux_in_nursery = !has_aux or vm.vm_asm.nursery.contains(@ptrFromInt(layouts.UNTAG(old_str.aux)));
    if (in_nursery and aux_in_nursery and new_length <= old_length) {
        const str_mut: *layouts.String = @ptrFromInt(layouts.UNTAG(str_cell));
        str_mut.length = layouts.tagFixnum(@intCast(new_length));

        if (has_aux) {
            const aux: *layouts.ByteArray = @ptrFromInt(layouts.UNTAG(str_mut.aux));
            aux.capacity = layouts.tagFixnum(@intCast(new_length * 2));
        }

        vm.push(str_cell);
        return;
    }

    // Root old string - allocation can trigger GC
    vm.data_roots.appendAssumeCapacity(&str_cell);
    defer _ = vm.data_roots.pop();

    // Use allotObject which routes large objects to tenured space
    const string_size = layouts.alignCell(@sizeOf(layouts.String) + new_length, layouts.data_alignment);

    var tagged = vm.allotObject(.string, string_size) orelse vm.memoryError();

    // Re-derive old_str from rooted str_cell (allotObject may trigger GC)
    old_str = @ptrFromInt(layouts.UNTAG(str_cell));

    var new_str: *layouts.String = @ptrFromInt(layouts.UNTAG(tagged));
    new_str.length = layouts.tagFixnum(@intCast(new_length));
    new_str.hashcode_field = layouts.false_object;
    // Initialize aux BEFORE the aux byte-array allocation below: that
    // allocation can trigger a GC which visits this string's slots, and an
    // uninitialized aux slot full of nursery garbage gets dereferenced as a
    // pointer (matches C++ allot_string_internal, which sets aux up front).
    new_str.aux = layouts.false_object;

    const copy_length = @min(old_length, new_length);
    @memcpy(new_str.data()[0..copy_length], old_str.data()[0..copy_length]);

    if (new_length > old_length) {
        @memset(new_str.data()[old_length..new_length], 0);
    }

    // Handle auxiliary byte_array for Unicode strings
    if (has_aux) {
        // Root the new string before second allocation
        vm.data_roots.appendAssumeCapacity(&tagged);
        defer _ = vm.data_roots.pop();

        const aux_capacity = new_length * 2;
        const aux_size = layouts.alignCell(@sizeOf(layouts.ByteArray) + aux_capacity, layouts.data_alignment);
        if (vm.allotObject(.byte_array, aux_size)) |aux_tagged| {
            const aux_addr = layouts.UNTAG(aux_tagged);
            const new_aux: *layouts.ByteArray = @ptrFromInt(aux_addr);
            new_aux.capacity = layouts.tagFixnum(@intCast(aux_capacity));

            // Re-derive pointers after GC (allotObject may trigger GC)
            const old_str2: *const layouts.String = @ptrFromInt(layouts.UNTAG(str_cell));
            const old_aux: *const layouts.ByteArray = @ptrFromInt(layouts.UNTAG(old_str2.aux));
            const aux_copy_length = @min(copy_length * 2, aux_capacity);
            @memcpy(new_aux.data()[0..aux_copy_length], old_aux.data()[0..aux_copy_length]);

            if (aux_capacity > copy_length * 2) {
                @memset(new_aux.data()[copy_length * 2 .. aux_capacity], 0);
            }

            // Re-derive new_str from rooted tagged (GC may have moved it)
            new_str = @ptrFromInt(layouts.UNTAG(tagged));
            new_str.aux = aux_tagged;
            // Barrier the old->young store (new_str may be aging/tenured after
            // the aux allocation; aux is a fresh nursery object).
            vm.writeBarrierKnownHeapWithValue(&new_str.aux, aux_tagged);
        } else {
            new_str = @ptrFromInt(layouts.UNTAG(tagged));
            new_str.aux = layouts.false_object;
        }
    } else {
        new_str.aux = layouts.false_object;
    }

    vm.push(tagged);
}

pub export fn primitive_set_string_nth_fast(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    // ( ch n string -- )
    const str_cell = vm.pop();
    const n = layouts.untagFixnum(vm.pop());
    const value = layouts.untagFixnum(vm.pop());

    if (!layouts.hasTag(str_cell, .string)) {
        return;
    }

    const str: *layouts.String = @ptrFromInt(layouts.UNTAG(str_cell));
    const data = str.data();
    const index: usize = @intCast(n);

    // Set the byte directly - Factor code handles Unicode encoding
    // For ASCII: value is the character directly
    // For non-ASCII: value is (char & 0x7f) | 0x80 (set by Factor's set-string-nth-slow)
    const unsigned_value: Cell = @bitCast(value);
    data[index] = @truncate(unsigned_value);
}

// --- Word Primitives ---

pub export fn primitive_word(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    // ( name vocabulary hashcode -- word )
    var hashcode = vm.pop();
    var vocab = vm.pop();
    var name = vm.pop();

    // Root all three - name and vocab are heap strings, allocation can trigger GC
    vm.data_roots.appendAssumeCapacity(&name);
    defer _ = vm.data_roots.pop();
    vm.data_roots.appendAssumeCapacity(&vocab);
    defer _ = vm.data_roots.pop();
    vm.data_roots.appendAssumeCapacity(&hashcode);
    defer _ = vm.data_roots.pop();

    var word_cell = vm.allotObject(.word, @sizeOf(layouts.Word)) orelse vm.memoryError();
    const word: *layouts.Word = @ptrFromInt(layouts.UNTAG(word_cell));
    word.hashcode_field = hashcode;
    word.name = name;
    word.vocabulary = vocab;
    word.def = vm.vm_asm.special_objects[@intFromEnum(objects.SpecialObject.undefined)];
    word.props = layouts.false_object;
    word.pic_def = layouts.false_object;
    word.pic_tail_def = layouts.false_object;
    word.subprimitive = layouts.false_object;
    word.entry_point = 0;

    // JIT compile the word's def quotation.
    vm.data_roots.appendAssumeCapacity(&word_cell);
    defer _ = vm.data_roots.pop();

    const def = word.def;
    const compiled = vm.jitCompileQuotationWithOwner(word_cell, def, true);
    const w: *layouts.Word = @ptrFromInt(layouts.UNTAG(word_cell));
    if (compiled) |cb| {
        w.entry_point = cb.entryPoint();
    }

    vm.push(word_cell);
}

pub export fn primitive_word_code(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    // ( word -- start end )
    const word_cell = vm.peek();

    if (!layouts.hasTag(word_cell, .word)) {
        vm.typeError(.word, word_cell);
    }

    const word: *const layouts.Word = @ptrFromInt(layouts.UNTAG(word_cell));
    const entry = word.entry_point;
    vm.replace(math.fromUnsignedCell(vm, entry));

    // Compute end address: code_block_addr + code_block.size()
    if (entry >= @sizeOf(CodeBlock)) {
        const block: *const CodeBlock = @ptrFromInt(entry - @sizeOf(CodeBlock));
        if (!block.isFree()) {
            vm.push(math.fromUnsignedCell(vm, @intFromPtr(block) + block.size()));
            return;
        }
    }
    vm.push(math.fromUnsignedCell(vm, entry));
}

pub export fn primitive_quotation_code(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    // ( quotation -- start end )
    const quot_cell = vm.peek();

    if (!layouts.hasTag(quot_cell, .quotation)) {
        vm.typeError(.quotation, quot_cell);
    }

    const quot: *const layouts.Quotation = @ptrFromInt(layouts.UNTAG(quot_cell));
    const entry = quot.entry_point;
    vm.replace(math.fromUnsignedCell(vm, entry));

    // Compute end address: code_block_addr + code_block.size()
    if (entry >= @sizeOf(CodeBlock)) {
        const block: *const CodeBlock = @ptrFromInt(entry - @sizeOf(CodeBlock));
        if (!block.isFree()) {
            vm.push(math.fromUnsignedCell(vm, @intFromPtr(block) + block.size()));
            return;
        }
    }
    vm.push(math.fromUnsignedCell(vm, entry));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const data_heap_mod = @import("../data_heap.zig");
const gc_fixture = @import("../gc_test_fixture.zig");

// Bare VM with a 1 MB nursery and no GC: every allocation below fits, so
// primitives never hit the collector.
const T = struct {
    vm: *FactorVM,
    heap: *data_heap_mod.DataHeap,
    stack_base: Cell,

    fn init() !T {
        const allocator = testing.allocator;
        const vm = try FactorVM.init(allocator);
        vm.vm_asm.ctx = try vm.newContext();
        vm.vm_asm.spare_ctx = try vm.newContext();
        const heap = try data_heap_mod.DataHeap.init(allocator, 1024 * 1024, 64 * 1024, 64 * 1024);
        vm.setDataHeap(heap);
        return .{ .vm = vm, .heap = heap, .stack_base = vm.vm_asm.ctx.datastack };
    }

    fn deinit(self: *T) void {
        self.heap.deinit();
        self.vm.cards_array = null;
        self.vm.decks_array = null;
        self.vm.deinit();
    }

    fn fields(self: *T) *VMAssemblyFields {
        return &self.vm.vm_asm;
    }

    fn push(self: *T, cell: Cell) void {
        self.vm.push(cell);
    }

    fn pushFixnum(self: *T, n: Fixnum) void {
        self.vm.push(layouts.tagFixnum(n));
    }

    fn pop(self: *T) Cell {
        return self.vm.pop();
    }

    fn expectBalanced(self: *T) !void {
        try testing.expectEqual(self.stack_base, self.vm.vm_asm.ctx.datastack);
    }

    fn array(self: *T, cells: []const Cell) Cell {
        const tagged = self.vm.allotArray(cells.len, layouts.false_object) orelse unreachable;
        @memcpy(arrayAt(tagged).data()[0..cells.len], cells);
        return tagged;
    }

    fn byteArray(self: *T, bytes: []const u8) Cell {
        const tagged = self.vm.allotByteArray(bytes.len);
        @memcpy(byteArrayAt(tagged).data()[0..bytes.len], bytes);
        return tagged;
    }

    // Nursery tuple layout (array-tagged) describing tuples with `slots` slots.
    fn tupleLayout(self: *T, slots: Cell) Cell {
        const tagged = self.vm.allotArray(gc_fixture.tuple_layout_capacity, layouts.false_object) orelse unreachable;
        const layout: *layouts.TupleLayout = @ptrFromInt(layouts.UNTAG(tagged));
        layout.klass = layouts.false_object;
        layout.size = layouts.tagFixnum(@intCast(slots));
        layout.echelon = layouts.tagFixnum(0);
        layout.data()[0] = layouts.false_object;
        layout.data()[1] = layouts.tagFixnum(0);
        return tagged;
    }

    fn string(self: *T, text: []const u8) Cell {
        self.pushFixnum(@intCast(text.len));
        self.pushFixnum('x');
        primitive_string(self.fields());
        const tagged = self.pop();
        @memcpy(stringAt(tagged).data()[0..text.len], text);
        return tagged;
    }
};

fn arrayAt(tagged: Cell) *layouts.Array {
    return @ptrFromInt(layouts.UNTAG(tagged));
}

fn byteArrayAt(tagged: Cell) *layouts.ByteArray {
    return @ptrFromInt(layouts.UNTAG(tagged));
}

fn stringAt(tagged: Cell) *layouts.String {
    return @ptrFromInt(layouts.UNTAG(tagged));
}

fn tupleAt(tagged: Cell) *layouts.Tuple {
    return @ptrFromInt(layouts.UNTAG(tagged));
}

fn objectAt(tagged: Cell) *layouts.Object {
    return @ptrFromInt(layouts.UNTAG(tagged));
}

fn expectArray(tagged: Cell, expected: []const Cell) !void {
    try testing.expect(layouts.hasTag(tagged, .array));
    const arr = arrayAt(tagged);
    try testing.expectEqual(expected.len, arr.getCapacity());
    try testing.expectEqualSlices(Cell, expected, arr.data()[0..expected.len]);
}

fn expectBytes(tagged: Cell, expected: []const u8) !void {
    try testing.expect(layouts.hasTag(tagged, .byte_array));
    const ba = byteArrayAt(tagged);
    try testing.expectEqual(expected.len, layouts.untagFixnumUnsigned(ba.capacity));
    try testing.expectEqualSlices(u8, expected, ba.data()[0..expected.len]);
}

fn fx(n: Fixnum) Cell {
    return layouts.tagFixnum(n);
}

test "primitive_array builds a filled array and roots a heap fill" {
    var t = try T.init();
    defer t.deinit();

    t.pushFixnum(3);
    t.pushFixnum(7);
    primitive_array(t.fields());
    try expectArray(t.pop(), &.{ fx(7), fx(7), fx(7) });

    t.pushFixnum(0);
    t.push(layouts.false_object);
    primitive_array(t.fields());
    try expectArray(t.pop(), &.{});

    // A heap object as fill is rooted across the allocation and stored as-is.
    const ba = t.byteArray("ab");
    t.pushFixnum(2);
    t.push(ba);
    primitive_array(t.fields());
    try expectArray(t.pop(), &.{ ba, ba });

    // A bignum capacity that fits a fixnum is accepted.
    const four = try bignum.fromInt64(t.vm, 4);
    t.push(layouts.tagBignum(four));
    t.pushFixnum(1);
    primitive_array(t.fields());
    try expectArray(t.pop(), &.{ fx(1), fx(1), fx(1), fx(1) });

    try t.expectBalanced();
}

test "primitive_resize_array grows with f, shrinks nursery arrays in place, rejects non-arrays" {
    var t = try T.init();
    defer t.deinit();

    const arr = t.array(&.{ fx(1), fx(2), fx(3) });

    t.pushFixnum(5);
    t.push(arr);
    primitive_resize_array(t.fields());
    const grown = t.pop();
    try testing.expect(grown != arr);
    try expectArray(grown, &.{ fx(1), fx(2), fx(3), layouts.false_object, layouts.false_object });
    try expectArray(arr, &.{ fx(1), fx(2), fx(3) });

    t.pushFixnum(2);
    t.push(arr);
    primitive_resize_array(t.fields());
    try testing.expectEqual(arr, t.pop());
    try expectArray(arr, &.{ fx(1), fx(2) });

    t.pushFixnum(2);
    t.push(arr);
    primitive_resize_array(t.fields());
    try testing.expectEqual(arr, t.pop());

    t.pushFixnum(2);
    t.pushFixnum(9);
    primitive_resize_array(t.fields());
    try testing.expectEqual(layouts.false_object, t.pop());

    try t.expectBalanced();
}

test "byte array primitives allocate zeroed, uninitialized and resized byte arrays" {
    var t = try T.init();
    defer t.deinit();

    t.pushFixnum(10);
    primitive_byte_array(t.fields());
    const ba = t.pop();
    try expectBytes(ba, &[_]u8{0} ** 10);

    t.pushFixnum(4);
    primitive_uninitialized_byte_array(t.fields());
    const raw = t.pop();
    try testing.expect(layouts.hasTag(raw, .byte_array));
    try testing.expectEqual(@as(Cell, 4), layouts.untagFixnumUnsigned(byteArrayAt(raw).capacity));

    for (byteArrayAt(ba).data()[0..10], 0..) |*b, i| b.* = @intCast(i + 1);

    // ( n byte-array -- new-byte-array ): growing copies and zero-fills.
    t.pushFixnum(16);
    t.push(ba);
    primitive_resize_byte_array(t.fields());
    const grown = t.pop();
    try testing.expect(grown != ba);
    try expectBytes(grown, &[_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 0, 0, 0, 0, 0, 0 });

    // Shrinking a nursery byte array only rewrites its capacity.
    t.pushFixnum(3);
    t.push(ba);
    primitive_resize_byte_array(t.fields());
    try testing.expectEqual(ba, t.pop());
    try expectBytes(ba, &[_]u8{ 1, 2, 3 });

    t.pushFixnum(3);
    t.push(ba);
    primitive_resize_byte_array(t.fields());
    try testing.expectEqual(ba, t.pop());

    t.pushFixnum(3);
    t.pushFixnum(9);
    primitive_resize_byte_array(t.fields());
    try testing.expectEqual(layouts.false_object, t.pop());

    try t.expectBalanced();
}

test "primitive_string fills ASCII directly and encodes non-ASCII through an aux array" {
    var t = try T.init();
    defer t.deinit();

    t.pushFixnum(5);
    t.pushFixnum('a');
    primitive_string(t.fields());
    const s = t.pop();
    try testing.expect(layouts.hasTag(s, .string));
    const str = stringAt(s);
    try testing.expectEqual(@as(usize, 5), str.getLength());
    try testing.expectEqualStrings("aaaaa", str.data()[0..5]);
    try testing.expectEqual(layouts.false_object, str.aux);
    try testing.expectEqual(layouts.false_object, str.hashcode_field);

    // U+03B1: low byte (ch & 0x7f) | 0x80, aux u16 (ch >> 7) ^ 1.
    t.pushFixnum(3);
    t.pushFixnum(0x3B1);
    primitive_string(t.fields());
    const s2 = t.pop();
    const str2 = stringAt(s2);
    try testing.expectEqual(@as(usize, 3), str2.getLength());
    try testing.expectEqualSlices(u8, &[_]u8{ 0xB1, 0xB1, 0xB1 }, str2.data()[0..3]);
    try testing.expect(layouts.hasTag(str2.aux, .byte_array));
    const aux = byteArrayAt(str2.aux);
    try testing.expectEqual(@as(Cell, 6), layouts.untagFixnumUnsigned(aux.capacity));
    try testing.expectEqualSlices(u8, &[_]u8{ 6, 0, 6, 0, 6, 0 }, aux.data()[0..6]);

    try t.expectBalanced();
}

test "primitive_resize_string copies, zero-fills, shrinks in place and carries the aux array" {
    var t = try T.init();
    defer t.deinit();

    const s = t.string("hello");

    t.pushFixnum(8);
    t.push(s);
    primitive_resize_string(t.fields());
    const grown = t.pop();
    try testing.expect(grown != s);
    const g = stringAt(grown);
    try testing.expectEqual(@as(usize, 8), g.getLength());
    try testing.expectEqualSlices(u8, "hello\x00\x00\x00", g.data()[0..8]);
    try testing.expectEqual(layouts.false_object, g.aux);
    try testing.expectEqual(layouts.false_object, g.hashcode_field);

    t.pushFixnum(2);
    t.push(s);
    primitive_resize_string(t.fields());
    try testing.expectEqual(s, t.pop());
    try testing.expectEqual(@as(usize, 2), stringAt(s).getLength());

    t.pushFixnum(2);
    t.push(s);
    primitive_resize_string(t.fields());
    try testing.expectEqual(s, t.pop());

    // A string with an aux array: growing allocates a new aux of 2*n bytes
    // holding the old high halves, shrinking in the nursery trims both.
    t.pushFixnum(3);
    t.pushFixnum(0x3B1);
    primitive_string(t.fields());
    const u = t.pop();

    t.pushFixnum(5);
    t.push(u);
    primitive_resize_string(t.fields());
    const u_grown = t.pop();
    try testing.expect(u_grown != u);
    const us = stringAt(u_grown);
    try testing.expectEqual(@as(usize, 5), us.getLength());
    try testing.expectEqualSlices(u8, &[_]u8{ 0xB1, 0xB1, 0xB1, 0, 0 }, us.data()[0..5]);
    try testing.expect(layouts.hasTag(us.aux, .byte_array));
    const aux = byteArrayAt(us.aux);
    try testing.expectEqual(@as(Cell, 10), layouts.untagFixnumUnsigned(aux.capacity));
    try testing.expectEqualSlices(u8, &[_]u8{ 6, 0, 6, 0, 6, 0, 0, 0, 0, 0 }, aux.data()[0..10]);

    t.pushFixnum(1);
    t.push(u);
    primitive_resize_string(t.fields());
    try testing.expectEqual(u, t.pop());
    try testing.expectEqual(@as(usize, 1), stringAt(u).getLength());
    try testing.expectEqual(@as(Cell, 2), layouts.untagFixnumUnsigned(byteArrayAt(stringAt(u).aux).capacity));

    try t.expectBalanced();
}

test "primitive_set_string_nth_fast stores a byte and ignores non-strings" {
    var t = try T.init();
    defer t.deinit();

    const s = t.string("abc");
    // ( ch n string -- )
    t.pushFixnum('Z');
    t.pushFixnum(1);
    t.push(s);
    primitive_set_string_nth_fast(t.fields());
    try testing.expectEqualStrings("aZc", stringAt(s).data()[0..3]);

    t.pushFixnum(0xB1);
    t.pushFixnum(2);
    t.push(s);
    primitive_set_string_nth_fast(t.fields());
    try testing.expectEqualSlices(u8, &[_]u8{ 'a', 'Z', 0xB1 }, stringAt(s).data()[0..3]);

    t.pushFixnum('Q');
    t.pushFixnum(0);
    t.pushFixnum(5);
    primitive_set_string_nth_fast(t.fields());
    try testing.expectEqualSlices(u8, &[_]u8{ 'a', 'Z', 0xB1 }, stringAt(s).data()[0..3]);

    try t.expectBalanced();
}

test "primitive_clone copies heap objects, resets the hashcode and leaves immediates alone" {
    var t = try T.init();
    defer t.deinit();

    const arr = t.array(&.{ fx(1), fx(2) });
    objectAt(arr).setHashcode(0x1234);

    t.push(arr);
    primitive_clone(t.fields());
    const copy = t.pop();
    try testing.expect(copy != arr);
    try expectArray(copy, &.{ fx(1), fx(2) });
    try testing.expectEqual(@as(Cell, 0), objectAt(copy).hashcode());
    try testing.expectEqual(@as(Cell, 0x1234), objectAt(arr).hashcode());
    try testing.expectEqual(layouts.TypeTag.array, objectAt(copy).getType());

    // The copy is independent of the original.
    arrayAt(copy).data()[0] = fx(99);
    try expectArray(arr, &.{ fx(1), fx(2) });

    t.pushFixnum(5);
    primitive_clone(t.fields());
    try testing.expectEqual(fx(5), t.pop());

    t.push(layouts.false_object);
    primitive_clone(t.fields());
    try testing.expectEqual(layouts.false_object, t.pop());

    const ba = t.byteArray("xyz");
    t.push(ba);
    primitive_clone(t.fields());
    const ba2 = t.pop();
    try testing.expect(ba2 != ba);
    try expectBytes(ba2, "xyz");

    const layout = t.tupleLayout(2);
    t.push(layout);
    primitive_tuple(t.fields());
    const tup = t.pop();
    tupleAt(tup).data()[0] = fx(7);
    tupleAt(tup).data()[1] = ba;
    t.push(tup);
    primitive_clone(t.fields());
    const tup2 = t.pop();
    try testing.expect(tup2 != tup);
    try testing.expect(layouts.hasTag(tup2, .tuple));
    try testing.expectEqual(layout, tupleAt(tup2).layout);
    try testing.expectEqualSlices(Cell, &.{ fx(7), ba }, tupleAt(tup2).data()[0..2]);

    try t.expectBalanced();
}

test "primitive_wrapper boxes the top of the stack" {
    var t = try T.init();
    defer t.deinit();

    t.pushFixnum(42);
    primitive_wrapper(t.fields());
    const w = t.pop();
    try testing.expect(layouts.hasTag(w, .wrapper));
    const wrapper: *const layouts.Wrapper = @ptrFromInt(layouts.UNTAG(w));
    try testing.expectEqual(fx(42), wrapper.object);

    const arr = t.array(&.{fx(1)});
    t.push(arr);
    primitive_wrapper(t.fields());
    const w2 = t.pop();
    const wrapper2: *const layouts.Wrapper = @ptrFromInt(layouts.UNTAG(w2));
    try testing.expectEqual(arr, wrapper2.object);

    try t.expectBalanced();
}

test "primitive_slot and primitive_set_slot address slots after the header" {
    var t = try T.init();
    defer t.deinit();

    const arr = t.array(&.{ fx(10), fx(20) });

    // Slot numbering counts the header: slot 0 is the raw header, slot 1 an
    // array's tagged capacity, slots 2.. its elements.
    t.push(arr);
    t.pushFixnum(0);
    primitive_slot(t.fields());
    try testing.expectEqual(@as(Cell, @intFromEnum(layouts.TypeTag.array)) << 2, t.pop());

    t.push(arr);
    t.pushFixnum(1);
    primitive_slot(t.fields());
    try testing.expectEqual(fx(2), t.pop());

    t.push(arr);
    t.pushFixnum(3);
    primitive_slot(t.fields());
    try testing.expectEqual(fx(20), t.pop());

    // ( value obj n -- )
    t.pushFixnum(99);
    t.push(arr);
    t.pushFixnum(2);
    primitive_set_slot(t.fields());
    try expectArray(arr, &.{ fx(99), fx(20) });

    const ba = t.byteArray("q");
    t.push(ba);
    t.push(arr);
    t.pushFixnum(3);
    primitive_set_slot(t.fields());
    try expectArray(arr, &.{ fx(99), ba });

    try t.expectBalanced();
}

fn cardPtr(f: *gc_fixture.Fixture, slot: *const Cell) *u8 {
    return @ptrFromInt(f.vm.vm_asm.cards_offset +% (@intFromPtr(slot) >> @intCast(vm_mod.card_bits)));
}

test "primitive_set_slot dirties the card only for an old-to-young pointer store" {
    var f: gc_fixture.Fixture = undefined;
    try f.init();
    defer f.deinit();

    const holder = f.tenuredArray(2, layouts.false_object);
    const young = f.nurseryArray(1, fx(1));
    const slot = &gc_fixture.arrayAt(holder).data()[0];
    const card = cardPtr(&f, slot);

    // Element i of an array is slot i + 2 (header, capacity, elements...).
    card.* = 0;
    f.vm.push(young);
    f.vm.push(holder);
    f.vm.push(fx(2));
    primitive_set_slot(&f.vm.vm_asm);
    try testing.expectEqual(young, slot.*);
    try testing.expectEqual(vm_mod.card_mark_mask, card.*);

    card.* = 0;
    f.vm.push(fx(5));
    f.vm.push(holder);
    f.vm.push(fx(3));
    primitive_set_slot(&f.vm.vm_asm);
    try testing.expectEqual(fx(5), gc_fixture.arrayAt(holder).data()[1]);
    try testing.expectEqual(@as(u8, 0), card.*);

    // Old-to-old stores do not dirty the card either.
    const other = f.tenuredArray(1, fx(3));
    card.* = 0;
    f.vm.push(other);
    f.vm.push(holder);
    f.vm.push(fx(2));
    primitive_set_slot(&f.vm.vm_asm);
    try testing.expectEqual(other, slot.*);
    try testing.expectEqual(@as(u8, 0), card.*);
}

test "primitive_tuple and primitive_tuple_boa build tuples from a layout" {
    var t = try T.init();
    defer t.deinit();

    const layout = t.tupleLayout(3);
    t.push(layout);
    primitive_tuple(t.fields());
    const tup = t.pop();
    try testing.expect(layouts.hasTag(tup, .tuple));
    try testing.expectEqual(layout, tupleAt(tup).layout);
    try testing.expectEqualSlices(Cell, &.{ layouts.false_object, layouts.false_object, layouts.false_object }, tupleAt(tup).data()[0..3]);
    try testing.expectEqual(@as(Cell, @intFromEnum(layouts.TypeTag.tuple)) << 2, tupleAt(tup).header);
    try testing.expectEqual(@as(Cell, 4), layouts.slotCount(tup));

    // ( slot-values... layout -- tuple ): slots are taken in stack order.
    t.pushFixnum(1);
    t.pushFixnum(2);
    t.pushFixnum(3);
    t.push(layout);
    primitive_tuple_boa(t.fields());
    const boa = t.pop();
    try testing.expect(layouts.hasTag(boa, .tuple));
    try testing.expectEqual(layout, tupleAt(boa).layout);
    try testing.expectEqualSlices(Cell, &.{ fx(1), fx(2), fx(3) }, tupleAt(boa).data()[0..3]);

    const empty_layout = t.tupleLayout(0);
    t.push(empty_layout);
    primitive_tuple_boa(t.fields());
    const empty = t.pop();
    try testing.expectEqual(empty_layout, tupleAt(empty).layout);
    try testing.expectEqual(@as(Cell, 1), layouts.slotCount(empty));

    try t.expectBalanced();
}

test "identity hashcodes are assigned once, stay stable and differ between objects" {
    var t = try T.init();
    defer t.deinit();

    t.pushFixnum(7);
    primitive_identity_hashcode(t.fields());
    try testing.expectEqual(fx(7), t.pop());

    t.push(layouts.false_object);
    primitive_identity_hashcode(t.fields());
    try testing.expectEqual(layouts.false_object, t.pop());

    const a = t.array(&.{fx(1)});
    t.push(a);
    primitive_identity_hashcode(t.fields());
    try testing.expectEqual(fx(0), t.pop());

    t.push(a);
    primitive_compute_identity_hashcode(t.fields());
    try testing.expectEqual(@as(Cell, 1), t.vm.object_counter);
    const hc = objectAt(a).hashcode();
    try testing.expect(hc != 0);
    try testing.expectEqual(layouts.TypeTag.array, objectAt(a).getType());

    t.push(a);
    primitive_identity_hashcode(t.fields());
    try testing.expectEqual(fx(@intCast(hc)), t.pop());
    t.push(a);
    primitive_identity_hashcode(t.fields());
    try testing.expectEqual(fx(@intCast(hc)), t.pop());

    const b = t.array(&.{fx(1)});
    t.push(b);
    primitive_compute_identity_hashcode(t.fields());
    try testing.expectEqual(@as(Cell, 2), t.vm.object_counter);
    try testing.expect(objectAt(b).hashcode() != hc);

    // Immediates are ignored and do not consume a counter value.
    t.pushFixnum(3);
    primitive_compute_identity_hashcode(t.fields());
    try testing.expectEqual(@as(Cell, 2), t.vm.object_counter);

    try t.expectBalanced();
}

test "word_code and quotation_code report the code block range or the bare entry point" {
    var t = try T.init();
    defer t.deinit();

    const word_cell = t.vm.allotObject(.word, @sizeOf(layouts.Word)) orelse unreachable;
    const word: *layouts.Word = @ptrFromInt(layouts.UNTAG(word_cell));
    word.hashcode_field = fx(0);
    word.name = layouts.false_object;
    word.vocabulary = layouts.false_object;
    word.def = layouts.false_object;
    word.props = layouts.false_object;
    word.pic_def = layouts.false_object;
    word.pic_tail_def = layouts.false_object;
    word.subprimitive = layouts.false_object;
    word.entry_point = 0;

    // No compiled code: both ends are the (zero) entry point.
    t.push(word_cell);
    primitive_word_code(t.fields());
    try testing.expectEqual(fx(0), t.pop());
    try testing.expectEqual(fx(0), t.pop());

    // A fake 64-byte code block whose entry point follows its header.
    var block_buf: [8]Cell align(16) = .{0} ** 8;
    const block: *CodeBlock = @ptrCast(&block_buf);
    block.initialize(.unoptimized, 64, 0);
    const entry = @intFromPtr(block) + @sizeOf(CodeBlock);
    word.entry_point = entry;

    t.push(word_cell);
    primitive_word_code(t.fields());
    try testing.expectEqual(fx(@intCast(@intFromPtr(block) + 64)), t.pop());
    try testing.expectEqual(fx(@intCast(entry)), t.pop());

    const quot_cell = t.vm.allotObject(.quotation, @sizeOf(layouts.Quotation)) orelse unreachable;
    const quot: *layouts.Quotation = @ptrFromInt(layouts.UNTAG(quot_cell));
    quot.array = layouts.false_object;
    quot.cached_effect = layouts.false_object;
    quot.cache_counter = fx(0);
    quot.entry_point = entry;

    t.push(quot_cell);
    primitive_quotation_code(t.fields());
    try testing.expectEqual(fx(@intCast(@intFromPtr(block) + 64)), t.pop());
    try testing.expectEqual(fx(@intCast(entry)), t.pop());

    // A freed block is not trusted for the end address.
    block.markFree(64);
    t.push(quot_cell);
    primitive_quotation_code(t.fields());
    try testing.expectEqual(fx(@intCast(entry)), t.pop());
    try testing.expectEqual(fx(@intCast(entry)), t.pop());

    try t.expectBalanced();
}

test "primitive_become remaps every reference to the old objects" {
    var f: gc_fixture.Fixture = undefined;
    try f.init();
    defer f.deinit();

    const old_obj = f.tenuredArray(1, fx(1));
    const new_obj = f.tenuredArray(1, fx(2));
    const holder = f.tenuredArray(2, old_obj);
    const layout = f.tenuredTupleLayout(1);
    const tup = f.tenuredTuple(layout, old_obj);
    const old_arr = f.tenuredArray(1, old_obj);
    const new_arr = f.tenuredArray(1, new_obj);

    f.vm.push(old_obj);
    f.vm.vm_asm.ctx.pushRetain(old_obj);
    f.vm.setSpecialObject(.walker_hook, old_obj);
    f.vm.vm_asm.ctx.context_objects[0] = old_obj;
    var rooted = old_obj;
    f.vm.data_roots.appendAssumeCapacity(&rooted);
    defer _ = f.vm.data_roots.pop();

    f.vm.push(old_arr);
    f.vm.push(new_arr);
    primitive_become(&f.vm.vm_asm);

    try testing.expectEqualSlices(Cell, &.{ new_obj, new_obj }, gc_fixture.arrayAt(holder).data()[0..2]);
    const tuple: *const layouts.Tuple = @ptrFromInt(layouts.UNTAG(tup));
    try testing.expectEqual(new_obj, tuple.data()[0]);
    try testing.expectEqual(new_obj, f.vm.vm_asm.ctx.popRetain());
    try testing.expectEqual(new_obj, f.vm.pop());
    try testing.expectEqual(new_obj, f.vm.specialObject(.walker_hook));
    try testing.expectEqual(new_obj, f.vm.vm_asm.ctx.context_objects[0]);
    try testing.expectEqual(new_obj, rooted);
    // The mapping arrays themselves are heap objects and are rewritten too.
    try testing.expectEqual(new_obj, gc_fixture.arrayAt(old_arr).data()[0]);
    // The replacement object is untouched.
    try testing.expectEqual(fx(2), gc_fixture.arrayAt(new_obj).data()[0]);
}
