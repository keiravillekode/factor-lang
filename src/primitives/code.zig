// primitives/code.zig - Code heap, quotation compilation, and method dispatch

const std = @import("std");
const builtin = @import("builtin");
const code_blocks = @import("../code_blocks.zig");
const contexts = @import("../contexts.zig");
const jit_protect = @import("../jit_protect.zig");
const jit_mod = @import("../jit.zig");
const layouts = @import("../layouts.zig");
const vm_mod = @import("../vm.zig");

const Cell = layouts.Cell;
const CodeBlock = code_blocks.CodeBlock;
const Fixnum = layouts.Fixnum;
const FactorVM = vm_mod.FactorVM;
const VMAssemblyFields = vm_mod.VMAssemblyFields;

// --- Code Heap Primitives ---

pub export fn primitive_modify_code_heap(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    var jit_scope = jit_protect.Scope.init();
    defer jit_scope.deinit();

    const reset_inline_caches = vm.pop();
    const update_existing_words = vm.pop();
    var rooted_alist = vm.pop();
    vm.data_roots.appendAssumeCapacity(&rooted_alist);
    defer _ = vm.data_roots.pop();

    if (!layouts.hasTag(rooted_alist, .array)) {
        vm.criticalError("modify_code_heap: expected alist array", rooted_alist);
        return;
    }

    const count = blk: {
        const alist: *const layouts.Array = @ptrFromInt(layouts.UNTAG(rooted_alist));
        break :blk layouts.untagFixnumUnsigned(alist.capacity);
    };

    if (count == 0) return;

    // Process each (word, code) pair
    for (0..count) |i| {
        // CRITICAL: Re-derive alist from rooted_alist each iteration because
        // jitCompileQuotationWithOwner (called in previous iterations) can trigger GC
        const alist_fresh: *const layouts.Array = @ptrFromInt(layouts.UNTAG(rooted_alist));
        var rooted_pair = alist_fresh.data()[i];
        vm.data_roots.appendAssumeCapacity(&rooted_pair);
        defer _ = vm.data_roots.pop();

        if (!layouts.hasTag(rooted_pair, .array)) {
            vm.criticalError("modify_code_heap: expected pair array", rooted_pair);
            return;
        }

        const pair: *const layouts.Array = @ptrFromInt(layouts.UNTAG(rooted_pair));
        if (layouts.untagFixnumUnsigned(pair.capacity) < 2) {
            vm.criticalError("modify_code_heap: pair must have word and payload", rooted_pair);
            return;
        }

        var rooted_word = pair.data()[0];
        var rooted_code = pair.data()[1];
        vm.data_roots.appendAssumeCapacity(&rooted_word);
        defer _ = vm.data_roots.pop();
        vm.data_roots.appendAssumeCapacity(&rooted_code);
        defer _ = vm.data_roots.pop();

        if (!layouts.hasTag(rooted_word, .word)) {
            vm.criticalError("modify_code_heap: expected word", rooted_word);
            return;
        }

        const code_tag = layouts.typeTag(rooted_code);

        switch (code_tag) {
            .quotation, .tuple => {
                // Quotation or tuple (curry/compose) case: JIT compile and update
                // QUOTATION_TYPE and TUPLE_TYPE (see issue #2763).

                // because quotation-compiled? depends on the identity of its code block.
                // Without this, recompiling lazy-jit-compile changes the sentinel
                // entry_point, causing all quotations with the OLD sentinel to appear
                // "compiled" (old_ep != new_ep), which creates infinite loops.
                const word_pre: *const layouts.Word = @ptrFromInt(layouts.UNTAG(rooted_word));
                if (word_pre.entry_point != 0 and
                    rooted_word == vm.specialObject(.lazy_jit_compile_word))
                {
                    continue;
                }

                // Compile the definition with the word as owner.
                // Code blocks are added to uninitialized_blocks and initialized later by
                // updateCodeHeapWords, after ALL word entry_points have been set.
                // This ensures cross-references between words resolve correctly.
                const compiled = vm.jitCompileQuotationWithOwner(rooted_word, rooted_code, false);
                const word_after: *layouts.Word = @ptrFromInt(layouts.UNTAG(rooted_word));
                if (compiled) |cb| {
                    word_after.entry_point = cb.entryPoint();
                } else {
                    word_after.entry_point = vm.lazyJitCompileEntryPoint();
                }

                // Compile pic_def and pic_tail_def if present.
                if (word_after.pic_def != layouts.false_object) {
                    vm.jitCompileQuotation(word_after.pic_def, false);
                }
                if (word_after.pic_tail_def != layouts.false_object) {
                    vm.jitCompileQuotation(word_after.pic_tail_def, false);
                }
            },
            .array => {
                // Array case: raw compiled code (optimized compilation)
                // Array contains: [parameters, literals, relocation, labels, code, frame_size]
                //
                // Phase 1 (here): Allocate code block, copy machine code, apply labels, set entry_point
                // Phase 2 (in updateCodeHeapWords): Apply relocations after ALL entry_points are set
                // This is critical because code blocks may reference each other.
                const code_arr: *const layouts.Array = @ptrFromInt(layouts.UNTAG(rooted_code));
                const arr_cap = layouts.untagFixnumUnsigned(code_arr.capacity);

                if (arr_cap < 6) {
                    vm.criticalError("modify_code_heap: optimized code payload too small", rooted_code);
                    return;
                }

                const arr_data = code_arr.data();
                var parameters_cell = arr_data[0];
                var literals_cell = arr_data[1];
                var relocation_cell = arr_data[2];
                var labels_cell = arr_data[3];
                var code_bytes_cell = arr_data[4];
                const frame_size = layouts.untagFixnumUnsigned(arr_data[5]);

                vm.data_roots.appendAssumeCapacity(&parameters_cell);
                defer _ = vm.data_roots.pop();
                vm.data_roots.appendAssumeCapacity(&literals_cell);
                defer _ = vm.data_roots.pop();
                vm.data_roots.appendAssumeCapacity(&relocation_cell);
                defer _ = vm.data_roots.pop();
                vm.data_roots.appendAssumeCapacity(&labels_cell);
                defer _ = vm.data_roots.pop();
                vm.data_roots.appendAssumeCapacity(&code_bytes_cell);
                defer _ = vm.data_roots.pop();

                if (!layouts.hasTag(code_bytes_cell, .byte_array)) {
                    vm.criticalError("modify_code_heap: expected code bytes byte-array", code_bytes_cell);
                    return;
                }

                const code_bytes_pre: *const layouts.ByteArray = @ptrFromInt(layouts.UNTAG(code_bytes_cell));
                const code_len = layouts.untagFixnumUnsigned(code_bytes_pre.capacity);

                // Allocate code block (triggers compaction if code heap is full)
                const header_size = @sizeOf(code_blocks.CodeBlock);
                const total_size = layouts.alignCell(header_size + code_len, layouts.data_alignment);

                const block = vm.allotCodeBlock(total_size);

                // Initialize the code block header (optimized type)
                block.initialize(.optimized, total_size, frame_size);
                block.owner = rooted_word;

                // Set relocation
                if (layouts.hasTag(relocation_cell, .byte_array)) {
                    const reloc_ba: *const layouts.ByteArray = @ptrFromInt(layouts.UNTAG(relocation_cell));
                    if (layouts.untagFixnumUnsigned(reloc_ba.capacity) > 0) {
                        block.relocation = relocation_cell;
                    } else {
                        block.relocation = layouts.false_object;
                    }
                } else {
                    block.relocation = layouts.false_object;
                }

                // Set parameters
                if (layouts.hasTag(parameters_cell, .array)) {
                    const params_arr: *const layouts.Array = @ptrFromInt(layouts.UNTAG(parameters_cell));
                    if (layouts.untagFixnumUnsigned(params_arr.capacity) > 0) {
                        block.parameters = parameters_cell;
                    } else {
                        block.parameters = layouts.false_object;
                    }
                } else {
                    block.parameters = layouts.false_object;
                }

                // Copy machine code (re-derive pointer after potential GC)
                const code_bytes: *const layouts.ByteArray = @ptrFromInt(layouts.UNTAG(code_bytes_cell));
                const code_dest = block.codeStart();
                @memcpy(code_dest[0..code_len], code_bytes.data()[0..code_len]);

                // Apply labels fixups if present (these are block-internal, safe to do now)
                if (labels_cell != layouts.false_object and layouts.hasTag(labels_cell, .array)) {
                    const labels_arr: *const layouts.Array = @ptrFromInt(layouts.UNTAG(labels_cell));
                    const labels_data = labels_arr.data();
                    const labels_cap = layouts.untagFixnumUnsigned(labels_arr.capacity);

                    var j: usize = 0;
                    while (j + 2 < labels_cap) : (j += 3) {
                        const rel_class_cell = labels_data[j];
                        const offset_cell = labels_data[j + 1];
                        const target_cell = labels_data[j + 2];

                        const rel_class: code_blocks.RelocationClass = @enumFromInt(@as(u4, @truncate(layouts.untagFixnumUnsigned(rel_class_cell))));
                        const offset: u24 = @truncate(layouts.untagFixnumUnsigned(offset_cell));
                        const target = layouts.untagFixnumUnsigned(target_cell);

                        const entry = code_blocks.RelocationEntry.init(.here, rel_class, offset);
                        var op = code_blocks.InstructionOperand.init(entry, block, 0);
                        const abs_value = target + block.entryPoint();
                        op.storeValue(@bitCast(abs_value));
                    }
                }

                // CRITICAL: Add write barrier so GC will scan this code block's
                // relocation/parameters/owner fields during nursery collection.
                // Without this, if a subsequent iteration triggers GC (e.g., via
                // jitCompileQuotationWithOwner), the nursery byte arrays referenced
                // by relocation/parameters could be moved without updating these fields.
                // The GC's scanCodeBlock already handles uninitialized blocks correctly
                // (skips embedded literals, only visits header fields).
                // write_barrier already called by allotCodeBlock

                // DO NOT apply relocations here! Defer to updateCodeHeapWords.
                // Store the literals cell in uninitialized_blocks so updateCodeHeapWords
                // can initialize this block later, after all word entry_points are set.
                const code_heap = vm.code orelse {
                    vm.criticalError("modify_code_heap: code heap not initialized", rooted_code);
                    return;
                };
                code_heap.putUninitializedBlock(vm.allocator, @intFromPtr(block), literals_cell) catch {
                    // Fall back to immediate initialization if tracking fails
                    vm.initializeCodeBlock(block, literals_cell);
                };

                // Set word entry point NOW (phase 1) so other blocks can reference it
                const word_after: *layouts.Word = @ptrFromInt(layouts.UNTAG(rooted_word));
                word_after.entry_point = block.entryPoint();
            },
            else => {
                vm.criticalError("Expected a quotation or an array", rooted_code);
                return;
            },
        }
    }

    // If update_existing_words is true, we need to update all code blocks
    // to point to the new entry points. This is critical for existing call
    // sites to use the newly compiled code.
    if (update_existing_words != layouts.false_object) {
        updateCodeHeapWords(vm, reset_inline_caches != layouts.false_object, &rooted_alist);
    }
    if (update_existing_words == layouts.false_object) {
        if (vm.code) |code_heap| {
            var iter = code_heap.uninitialized_blocks.iterator();
            while (iter.next()) |entry| {
                const block: *code_blocks.CodeBlock = @ptrFromInt(entry.key_ptr.*);
                vm.initializeCodeBlock(block, entry.value_ptr.*);
            }
            code_heap.clearUninitializedBlocks();
        }
    }
}

// Update all code blocks to point to current word entry points.
// redefined_alist, when given, points at a GC-rooted cell holding the
// compilation unit's alist; only PICs referencing one of its words are
// invalidated instead of every PIC in the code heap.
pub fn updateCodeHeapWords(vm: *FactorVM, reset_inline_caches: bool, redefined_alist: ?*const Cell) void {
    var jit_scope = jit_protect.Scope.init();
    defer jit_scope.deinit();

    const code_heap = vm.code orelse return;

    // Pre-compilation pass: ensure all quotation literals in uninitialized
    // blocks have valid entry_points. Without this, applyRelocations sets
    // RT_ENTRY_POINT to lazy_jit_compile_ep, and updateWordReferences can
    // never fix it (loadCodeBlock follows the target to the lazy_jit_compile
    // code block, whose owner resolves back to lazy_jit_compile_ep).
    preCompileQuotationLiterals(vm);

    // Initialize all uninitialized blocks upfront by iterating the small map
    // directly, instead of checking every block against the map in the main loop.
    {
        var iter = code_heap.uninitialized_blocks.iterator();
        while (iter.next()) |entry| {
            const block: *CodeBlock = @ptrFromInt(entry.key_ptr.*);
            vm.initializeCodeBlock(block, entry.value_ptr.*);
        }
        code_heap.clearUninitializedBlocks();
    }

    code_heap.flushPending();
    const blocks = code_heap.all_blocks_sorted.items;
    if (blocks.len == 0) return;

    const max_pic_size = vm.max_pic_size;
    const lazy_jit_ep = vm.lazyJitCompileEntryPoint();

    // Selective PIC invalidation: only PICs referencing a word redefined in
    // this compilation unit can hold stale dispatch decisions, so free just
    // those instead of every PIC. The set is built here, after the compile
    // passes above, because compiling can GC and move the word objects;
    // redefined_alist points at a GC-rooted cell so it is read fresh.
    var redefined_words: std.AutoHashMapUnmanaged(Cell, void) = .empty;
    defer redefined_words.deinit(vm.allocator);
    var selective = false;
    if (reset_inline_caches) {
        if (redefined_alist) |alist_ptr| {
            const alist: *const layouts.Array = @ptrFromInt(layouts.UNTAG(alist_ptr.*));
            const count = layouts.untagFixnumUnsigned(alist.capacity);
            selective = true;
            for (0..count) |i| {
                const pair: *const layouts.Array = @ptrFromInt(layouts.UNTAG(alist.data()[i]));
                redefined_words.put(vm.allocator, pair.data()[0], {}) catch {
                    // Fall back to blanket invalidation if the set can't grow.
                    selective = false;
                    break;
                };
            }
        }
    }

    var has_pics = false;

    // Free stale PICs before the patch pass so their call sites observe
    // isFree() and get reset to the miss stub, while call sites of surviving
    // PICs are left intact. This must complete before any patching: with the
    // interleaved single pass below, a call site patched early would keep
    // pointing at a PIC freed later in the walk.
    if (reset_inline_caches and selective) {
        for (blocks) |block_addr| {
            const block: *CodeBlock = @ptrFromInt(block_addr);
            if (block.isFree()) continue;
            if (block.blockType() == .pic and
                code_blocks.picReferencesWords(block, &redefined_words))
            {
                code_heap.freeBlockOnly(block);
                has_pics = true;
            }
        }
    }

    // Patch pass: update word references and, in blanket mode, mark PIC
    // blocks for removal. PIC blocks are freed in-place (marked free + added
    // to the free list) but their removal from all_blocks_sorted is done via
    // a compact pass below.
    for (blocks) |block_addr| {
        const block: *CodeBlock = @ptrFromInt(block_addr);
        if (block.isFree()) continue;

        if (reset_inline_caches and !selective and block.blockType() == .pic) {
            code_heap.freeBlockOnly(block);
            has_pics = true;
            continue;
        }

        if (!code_heap.blockHasCodePointers(block)) continue;

        code_blocks.updateWordReferences(block, reset_inline_caches, selective, max_pic_size, lazy_jit_ep);
    }

    // Compact all_blocks_sorted to remove freed PIC entries
    if (has_pics) {
        var write: usize = 0;
        for (code_heap.all_blocks_sorted.items) |addr| {
            const b: *const CodeBlock = @ptrFromInt(addr);
            if (!b.isFree()) {
                code_heap.all_blocks_sorted.items[write] = addr;
                write += 1;
            }
        }
        code_heap.all_blocks_sorted.items.len = write;
    }
}

// Pre-compile quotation literals in uninitialized code blocks.
// Only scans literals referenced by entry-point relocation slots, instead of
// walking every literal cell in every block.
fn preCompileQuotationLiterals(vm: *FactorVM) void {
    const code_heap = vm.code orelse return;
    if (code_heap.uninitialized_blocks.count() == 0) return;

    const lazy_ep = vm.lazyJitCompileEntryPoint();

    // Collect uncompiled quotation literals first (can't compile while iterating
    // uninitialized_blocks because compilation may trigger GC/compaction).
    var to_compile: std.ArrayListUnmanaged(Cell) = .empty;
    defer to_compile.deinit(vm.allocator);

    var iter = code_heap.uninitialized_blocks.iterator();
    while (iter.next()) |entry| {
        const block_addr = entry.key_ptr.*;
        const literals_cell = entry.value_ptr.*;
        if (literals_cell == layouts.false_object) continue;
        if (!layouts.hasTag(literals_cell, .array)) continue;

        const block: *const CodeBlock = @ptrFromInt(block_addr);
        if (block.relocation == layouts.false_object) continue;
        if (!layouts.hasTag(block.relocation, .byte_array)) continue;

        const lit_arr: *const layouts.Array = @ptrFromInt(layouts.UNTAG(literals_cell));
        const lit_data = lit_arr.data();
        const lit_cap = layouts.untagFixnumUnsigned(lit_arr.capacity);

        const reloc_ba: *const layouts.ByteArray = @ptrFromInt(layouts.UNTAG(block.relocation));
        const reloc_data = reloc_ba.data();
        const reloc_count = layouts.untagFixnumUnsigned(reloc_ba.capacity) / @sizeOf(code_blocks.RelocationEntry);

        var literal_index: usize = 0;
        for (0..reloc_count) |i| {
            const entry_ptr: *const code_blocks.RelocationEntry =
                @ptrCast(@alignCast(reloc_data + i * @sizeOf(code_blocks.RelocationEntry)));
            const rel_type = entry_ptr.getType();

            switch (rel_type) {
                .entry_point => {
                    if (literal_index >= lit_cap) break;
                    const lit = lit_data[literal_index];
                    literal_index += 1;

                    if (!layouts.hasTag(lit, .quotation)) continue;
                    const q: *const layouts.Quotation = @ptrFromInt(layouts.UNTAG(lit));
                    if (q.entry_point == 0 or q.entry_point == lazy_ep) {
                        to_compile.append(vm.allocator, lit) catch continue;
                    }
                },
                .entry_point_pic, .entry_point_pic_tail, .literal, .here, .untagged => {
                    literal_index += 1;
                },
                else => {},
            }
        }
    }

    if (to_compile.items.len > 0) {
        // Root all quotation cells to protect from GC during compilation.
        vm.data_roots.ensureUnusedCapacity(vm.allocator, to_compile.items.len + 32) catch @panic("OOM");
        for (to_compile.items) |*cell_ptr| {
            vm.data_roots.appendAssumeCapacity(cell_ptr);
        }
        defer {
            // Pop all roots we added
            var k: usize = 0;
            while (k < to_compile.items.len) : (k += 1) {
                _ = vm.data_roots.pop();
            }
        }

        for (to_compile.items) |quot_cell| {
            // Re-check entry_point (may have been compiled as a dependency)
            if (layouts.hasTag(quot_cell, .quotation)) {
                const q: *const layouts.Quotation = @ptrFromInt(layouts.UNTAG(quot_cell));
                if (q.entry_point == 0 or q.entry_point == lazy_ep) {
                    vm.jitCompileQuotation(quot_cell, true);
                }
            }
        }
    }
}

pub export fn primitive_code_blocks(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    // ( -- array )
    // Returns an array describing all code blocks in the code heap. Each code
    // block contributes 6 elements:
    //   owner, parameters, relocation, type (fixnum), size (fixnum), entry_point
    //
    // We must NOT allocate on the Factor heap while reading the code heap. The
    // result-array allocation can trigger a GC (and, on arm64, a code-heap
    // compaction) that relocates blocks and invalidates an in-progress scan,
    // yielding garbage / non-16-aligned entry points (which library code then
    // reads as tagged pointers instead of fixnums). This mirrors the C++ VM
    // (vm/code_heap.cpp primitive_code_blocks + vm/arrays.cpp
    // std_vector_to_array): capture every block's fields in one uninterrupted
    // pass into a side buffer, register the captured cells as GC data roots so
    // the collector fixes up the tagged pointers, then allocate the result
    // array once and copy in.
    const code_heap = vm.code orelse {
        vm.push(layouts.false_object);
        return;
    };
    const alloc = code_heap.free_list orelse {
        vm.push(layouts.false_object);
        return;
    };

    // First pass: count live code blocks (no allocation).
    var count: Cell = 0;
    {
        var scan = alloc.start;
        while (scan < alloc.end) {
            const block: *const CodeBlock = @ptrFromInt(scan);
            const block_size = block.size();
            if (block_size == 0) break;
            if (!block.isFree()) count += 1;
            scan += block_size;
        }
    }

    // Second pass: capture each live block's six fields into a side buffer on
    // the Zig heap. Growing this buffer never touches the Factor heap, so the
    // code-heap layout stays fixed across the whole scan.
    var objects: std.ArrayList(Cell) = .empty;
    defer objects.deinit(vm.allocator);
    objects.ensureUnusedCapacity(vm.allocator, count * 6) catch vm.memoryError();
    {
        var scan = alloc.start;
        while (scan < alloc.end) {
            const block: *const CodeBlock = @ptrFromInt(scan);
            const block_size = block.size();
            if (block_size == 0) break;
            if (!block.isFree()) {
                objects.appendAssumeCapacity(block.owner);
                objects.appendAssumeCapacity(block.parameters);
                objects.appendAssumeCapacity(block.relocation);
                objects.appendAssumeCapacity(layouts.tagFixnum(@intCast(@intFromEnum(block.blockType()))));
                objects.appendAssumeCapacity(layouts.tagFixnum(@intCast(block_size)));
                // Entry point is data_alignment-aligned (16 bytes), so its low
                // tag bits are 0 (FIXNUM_TYPE); library code shifts it left by
                // tag_bits to recover the address. Captured from the live heap,
                // it is always a valid fixnum.
                objects.appendAssumeCapacity(block.entryPoint());
            }
            scan += block_size;
        }
    }
    const element_count = objects.items.len;

    // Register the captured cells as data roots so a GC during the array
    // allocation fixes up the tagged pointers (owner/parameters/relocation).
    // The fixnum cells (type/size/entry_point) are ignored by the collector.
    const roots_base = vm.data_roots.items.len;
    vm.data_roots.ensureUnusedCapacity(vm.allocator, element_count) catch vm.memoryError();
    for (objects.items) |*cell_ptr| {
        vm.data_roots.appendAssumeCapacity(cell_ptr);
    }

    const array_cell = vm.allotArray(@intCast(element_count), layouts.false_object) orelse {
        vm.data_roots.shrinkRetainingCapacity(roots_base);
        vm.memoryError();
    };
    vm.data_roots.shrinkRetainingCapacity(roots_base);

    const arr: *layouts.Array = @ptrFromInt(layouts.UNTAG(array_cell));
    const data = arr.data();
    @memcpy(data[0..element_count], objects.items);

    vm.push(array_cell);
}

pub export fn primitive_strip_stack_traces(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    const code_heap = vm.code orelse return;

    var jit_scope = jit_protect.Scope.init();
    defer jit_scope.deinit();

    code_heap.flushPending();
    for (code_heap.all_blocks_sorted.items) |block_addr| {
        const block: *CodeBlock = @ptrFromInt(block_addr);
        if (!block.isFree()) {
            block.owner = layouts.false_object;
        }
    }
}

// --- Single-stepper Primitives ---

pub export fn primitive_innermost_stack_frame_executing(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    // ( callstack -- quotation )
    // Returns the quotation being executed in the innermost stack frame
    const cs_cell = vm.peek();

    vm.checkTag(cs_cell, .callstack);

    const callstack: *const layouts.Callstack = @ptrFromInt(layouts.UNTAG(cs_cell));
    const code = vm.code orelse @panic("no code heap");

    // Get the top frame
    const frame = callstack.top();
    const addr_ptr: *const Cell = @ptrFromInt(frame + contexts.FRAME_RETURN_ADDRESS);
    const addr = addr_ptr.*;

    // Find the code block for this address
    const block = code.codeBlockForAddress(addr) orelse {
        vm.replace(layouts.false_object);
        return;
    };

    // Replace with the owner quotation
    vm.replace(block.ownerQuot());
}

pub export fn primitive_innermost_stack_frame_scan(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    // ( callstack -- n )
    // Returns the scan offset for single-stepping in the innermost frame
    const cs_cell = vm.peek();

    vm.checkTag(cs_cell, .callstack);

    const callstack: *const layouts.Callstack = @ptrFromInt(layouts.UNTAG(cs_cell));
    const code = vm.code orelse @panic("no code heap");

    // Get the top frame
    const frame = callstack.top();
    const addr_ptr: *const Cell = @ptrFromInt(frame + contexts.FRAME_RETURN_ADDRESS);
    const addr = addr_ptr.*;

    // Find the code block for this address
    const block = code.codeBlockForAddress(addr) orelse {
        vm.replace(layouts.false_object);
        return;
    };

    // Replace with the scan value
    vm.replace(block.scan(vm, addr));
}

pub export fn primitive_set_innermost_stack_frame_quotation(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    // ( quot callstack -- )
    // Patches the innermost frame to execute a different quotation
    // Used by the single-stepper to modify execution flow
    var cs_cell = vm.pop();
    var quot_cell = vm.pop();

    vm.checkTag(cs_cell, .callstack);
    vm.checkTag(quot_cell, .quotation);

    // Compile the new quotation before patching the frame PC into it (matches
    // C++ jit_compile_quotation); otherwise entry_point is the lazy-jit stub
    // and entry_point+offset is a garbage PC. Root both cells across the GC.
    vm.data_roots.appendAssumeCapacity(&cs_cell);
    defer _ = vm.data_roots.pop();
    vm.data_roots.appendAssumeCapacity(&quot_cell);
    defer _ = vm.data_roots.pop();
    vm.jitCompileQuotation(quot_cell, true);

    const callstack: *const layouts.Callstack = @ptrFromInt(layouts.UNTAG(cs_cell));
    const quot: *const layouts.Quotation = @ptrFromInt(layouts.UNTAG(quot_cell));
    const code = vm.code orelse return;

    // Get the innermost frame
    const inner = callstack.top() + contexts.FRAME_RETURN_ADDRESS;
    const addr_ptr: *Cell = @ptrFromInt(inner);
    const addr = addr_ptr.*;

    // Find the code block for the current address
    const block = code.codeBlockForAddress(addr) orelse return;

    // Calculate the offset within the current code block
    const offset_val = block.offset(addr);

    // Patch the return address to point to the new quotation at the same offset
    addr_ptr.* = quot.entry_point + offset_val;
}

// --- Quotation Primitives ---

pub export fn primitive_quotation_compiled_p(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    // ( quot -- ? )
    const quot_cell = vm.pop();
    if (!layouts.hasTag(quot_cell, .quotation)) {
        vm.push(layouts.false_object);
        return;
    }
    const quot: *const layouts.Quotation = @ptrFromInt(layouts.UNTAG(quot_cell));
    // Quotation is compiled if entry_point is non-zero and not lazy_jit_compile stub
    const compiled = jit_mod.isQuotationCompiled(vm, quot);
    vm.push(vm.tagBoolean(compiled));
}

pub export fn primitive_jit_compile(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    // ( quot -- )
    const quot_cell = vm.pop();
    vm.jitCompileQuotation(quot_cell, true);
}

pub export fn primitive_array_to_quotation(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    // ( array -- quotation )
    // quotation* quot = allot<quotation>(sizeof(quotation));
    // quot->array = ctx->peek();
    // quot->cached_effect = false_object;
    // quot->cache_counter = false_object;
    // quot->entry_point = lazy_jit_compile_entry_point();
    // ctx->replace(tag<quotation>(quot));

    const tagged = vm.allotObject(.quotation, @sizeOf(layouts.Quotation)) orelse {
        vm.memoryError();
        return;
    };

    // Peek AFTER allotObject - arr may have been moved by GC
    const arr = vm.peek();

    const quot: *layouts.Quotation = @ptrFromInt(layouts.UNTAG(tagged));
    quot.array = arr;
    quot.cached_effect = layouts.false_object;
    quot.cache_counter = layouts.false_object;
    quot.entry_point = vm.lazyJitCompileEntryPoint();
    vm.replace(tagged);
}

// --- Word Primitives ---

pub export fn primitive_word_optimized_p(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    // ( word -- ? )
    const word_cell = vm.peek();
    vm.checkTag(word_cell, .word);
    const word: *const layouts.Word = @ptrFromInt(layouts.UNTAG(word_cell));
    const block: *const code_blocks.CodeBlock = @ptrFromInt(word.entry_point - @sizeOf(code_blocks.CodeBlock));
    vm.replace(vm.tagBoolean(block.blockType() == .optimized));
}

// --- Dispatch Primitives ---

pub export fn primitive_lookup_method(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const ctx = vm_asm.ctx;
    // ( object methods -- method )
    const methods = ctx.pop();
    const object = ctx.pop();
    const method = lookupMethod(object, methods);
    ctx.push(method);
}

// For tuples, returns the layout; for other types, returns the tagged fixnum of the tag.
// No forwarding pointer following needed outside of GC since all references are
// updated after collection completes.
pub fn objectClass(object: Cell) Cell {
    const tag = layouts.typeTag(object);
    if (tag == .tuple) {
        const tuple: *const layouts.Tuple = @ptrFromInt(layouts.UNTAG(object));
        return tuple.layout;
    }
    return layouts.tagFixnum(@as(Fixnum, @intCast(@intFromEnum(tag))));
}

fn methodCacheHashcode(klass: Cell, cache_arr: *const layouts.Array) Cell {
    const capacity = layouts.untagFixnumFast(cache_arr.capacity);
    // capacity >> 1 gives number of pairs, - 1 for mask
    const mask = (capacity >> 1) - 1;
    // Shift klass right by tag bits, mask, then shift left for pair indexing
    return ((klass >> layouts.tag_bits) & mask) << 1;
}

fn updateMethodCache(vm: *FactorVM, cache: Cell, klass: Cell, method: Cell) void {
    const cache_arr: *layouts.Array = @ptrFromInt(layouts.UNTAG(cache));
    const hashcode = methodCacheHashcode(klass, cache_arr);
    const data = cache_arr.data();

    if (data[hashcode] == klass and data[hashcode + 1] == method) {
        return;
    }

    data[hashcode] = klass;
    data[hashcode + 1] = method;

    // method_cache_hashcode() always returns an even index, so this pair
    // occupies a single card/deck-aligned 2-cell slot. Mark once.
    const slot0 = &data[hashcode];
    const slot1 = &data[hashcode + 1];
    std.debug.assert((@intFromPtr(slot0) >> vm_mod.card_bits) == (@intFromPtr(slot1) >> vm_mod.card_bits));
    vm.writeBarrierKnownHeap(slot0);
}

pub export fn primitive_mega_cache_miss(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    const ctx = vm_asm.ctx;
    // ( methods index cache -- method )
    vm.dispatch_stats.megamorphic_cache_misses += 1;

    const cache = ctx.pop();
    const index_cell = ctx.pop();
    const methods = ctx.pop();

    const index = layouts.untagFixnum(index_cell);

    const stack_addr = ctx.datastack -% (@as(Cell, @intCast(index)) * @sizeOf(Cell));
    const object = @as(*const Cell, @ptrFromInt(stack_addr)).*;

    const lookup = lookupMethodAndClass(object, methods);

    updateMethodCache(vm, cache, lookup.klass, lookup.method);

    ctx.push(lookup.method);
}

inline fn searchLookupAlist(table: Cell, klass: Cell) Cell {
    const elements: *const layouts.Array = @ptrFromInt(layouts.UNTAG(table));
    const cap: Cell = layouts.untagFixnumUnsigned(elements.capacity);
    const data = elements.data();

    if (cap == 0) return layouts.false_object;

    var index: usize = cap - 2;
    while (true) {
        if (data[index] == klass) return data[index + 1];
        if (index == 0) break;
        index -= 2;
    }
    return layouts.false_object;
}

fn searchLookupHash(table: Cell, klass: Cell, hashcode: Cell) Cell {
    const buckets: *const layouts.Array = @ptrFromInt(layouts.UNTAG(table));

    std.debug.assert(layouts.hasTag(buckets.capacity, .fixnum));

    const cap: Cell = @intCast(layouts.untagFixnum(buckets.capacity));
    const bucket_idx = hashcode & (cap - 1);
    const bucket = buckets.data()[bucket_idx];

    if (layouts.hasTag(bucket, .array)) {
        return searchLookupAlist(bucket, klass);
    }
    return bucket;
}

fn lookupTupleMethod(layout: *const layouts.TupleLayout, methods: Cell) Cell {
    const echelons: *const layouts.Array = @ptrFromInt(layouts.UNTAG(methods));

    std.debug.assert(layouts.hasTag(echelons.capacity, .fixnum));
    std.debug.assert(layouts.hasTag(layout.echelon, .fixnum));

    const echelons_cap = layouts.untagFixnum(echelons.capacity);
    const echelons_data = echelons.data();
    const layout_data = layout.data();

    var echelon: isize = @min(layouts.untagFixnum(layout.echelon), echelons_cap - 1);

    while (echelon >= 0) {
        const echelon_idx: usize = @intCast(echelon);
        const echelon_methods = echelons_data[echelon_idx];

        if (layouts.hasTag(echelon_methods, .word)) {
            return echelon_methods;
        } else if (echelon_methods != layouts.false_object) {
            const tuple_data_idx = echelon_idx * 2;
            const klass = layout_data[tuple_data_idx];
            const hashcode_raw = layout_data[tuple_data_idx + 1];

            std.debug.assert(layouts.hasTag(hashcode_raw, .fixnum));

            const hashcode: Cell = @bitCast(layouts.untagFixnum(hashcode_raw));
            const result = searchLookupHash(echelon_methods, klass, hashcode);
            if (result != layouts.false_object) {
                return result;
            }
        }

        echelon -= 1;
    }

    // This path should never be reached with valid data.
    if (comptime std.debug.runtime_safety) unreachable;
    return layouts.false_object;
}

pub const MethodLookup = struct {
    method: Cell,
    klass: Cell,
};

pub inline fn lookupMethod(object: Cell, methods: Cell) Cell {
    return lookupMethodAndClass(object, methods).method;
}

pub fn lookupMethodAndClass(object: Cell, methods: Cell) MethodLookup {
    const methods_arr: *const layouts.Array = @ptrFromInt(layouts.UNTAG(methods));
    const tag: Cell = layouts.TAG(object);

    std.debug.assert(tag < layouts.untagFixnumFast(methods_arr.capacity));

    const method = methods_arr.data()[tag];

    if (!layouts.hasTag(object, .tuple)) {
        return .{
            .method = method,
            .klass = layouts.tagFixnum(@as(Fixnum, @intCast(tag))),
        };
    }

    const tuple: *const layouts.Tuple = @ptrFromInt(layouts.UNTAG(object));
    const layout: *const layouts.TupleLayout = @ptrFromInt(layouts.UNTAG(tuple.layout));

    const resolved_method = if (layouts.hasTag(method, .array))
        lookupTupleMethod(layout, method)
    else
        method;

    return .{
        .method = resolved_method,
        .klass = tuple.layout,
    };
}

// --- Callstack Primitives ---

// Used by callstack_for to skip the primitive's own frame and its caller
fn secondFromTopStackFrame(vm: *FactorVM, ctx: *const contexts.Context) Cell {
    var frame_top = ctx.callstack_top;
    const bottom = ctx.callstack_bottom;

    // Skip 2 frames using frame_predecessor
    const code = vm.code orelse {
        // No code heap - fall back to returning original top
        return frame_top;
    };

    for (0..2) |_| {
        const pred = code.framePredecessor(frame_top);

        if (pred >= bottom) {
            // Reached bottom of callstack
            return frame_top;
        }
        frame_top = pred;
    }

    return frame_top;
}

pub export fn primitive_callstack_for(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    // ( context -- callstack )
    const ctx_cell = vm.peek();

    const other_ctx = vm.getContextFromAlien(ctx_cell);
    if (other_ctx == null) {
        vm.replace(layouts.false_object);
        return;
    }

    const ctx = other_ctx.?;

    // This skips 2 frames from the top because the 'callstack' primitive frame
    // and its caller frame should not be included - otherwise set-callstack
    // would loop forever.
    const top = secondFromTopStackFrame(vm, ctx);
    const bottom = ctx.callstack_bottom;

    // already skipped the primitive frame and its caller, so bottom - top gives
    // the correct callstack size to capture.
    const size: Cell = if (bottom > top) bottom - top else 0;

    // Allocate callstack object, triggering GC if needed
    const callstack_size = @sizeOf(layouts.Callstack) + size;
    const tagged = vm.allotObject(.callstack, callstack_size) orelse {
        vm.memoryError();
        return;
    };
    const callstack: *layouts.Callstack = @ptrFromInt(layouts.UNTAG(tagged));
    callstack.length = layouts.tagFixnum(@intCast(size));

    if (size > 0) {
        const src: [*]const u8 = @ptrFromInt(top);
        const dest: [*]u8 = @ptrFromInt(callstack.top());
        @memcpy(dest[0..size], src[0..size]);

        // On arm64, convert absolute saved frame pointers to relative offsets so
        // the callstack object can move through memory; set-callstack converts
        // them back (FP = top + delta). Mirrors C++ capture_callstack
        // (vm/callstack.cpp) and the FACTOR_ARM64 block there. Without this the
        // restore loop follows garbage frame pointers and overruns the stack.
        if (builtin.cpu.arch == .aarch64) {
            var scan_top = top;
            var scan_dst = callstack.top();
            while (scan_top < bottom) {
                const saved_fp = @as(*const Cell, @ptrFromInt(scan_top)).*;
                if (saved_fp <= scan_top) break;
                const dst_ptr: *Cell = @ptrFromInt(scan_dst);
                dst_ptr.* = saved_fp - scan_top;
                scan_top = saved_fp;
                scan_dst += dst_ptr.*;
            }
        }
    }

    vm.replace(tagged);
}

// --- Tests ---

const testing = std.testing;
const data_heap_mod = @import("../data_heap.zig");
const code_heap_mod = @import("../code_heap.zig");
const free_list_mod = @import("../free_list.zig");
const write_barrier_mod = @import("../write_barrier.zig");
const objects_mod = @import("../objects.zig");

// A bare VM with a data heap and a code heap over plain (never executed)
// memory, enough to drive the code-heap primitives without an image.
const TestVM = struct {
    vm: *FactorVM,
    heap: *data_heap_mod.DataHeap,
    region: []u8,
    code_alloc: free_list_mod.FreeListAllocator,
    code_heap: code_heap_mod.CodeHeap,
    true_obj: Cell,
    stack_base: Cell,

    fn init(self: *TestVM) !void {
        const allocator = testing.allocator;
        self.vm = try FactorVM.init(allocator);
        self.vm.vm_asm.ctx = try self.vm.newContext();
        self.vm.vm_asm.spare_ctx = try self.vm.newContext();
        self.heap = try data_heap_mod.DataHeap.init(allocator, 256 * 1024, 64 * 1024, 64 * 1024);
        self.vm.setDataHeap(self.heap);

        const size: Cell = 64 * 1024;
        self.region = try std.heap.page_allocator.alloc(u8, size);
        @memset(self.region, 0);
        const start = @intFromPtr(self.region.ptr);
        self.code_alloc = free_list_mod.FreeListAllocator.init(allocator, start, size);
        self.code_heap = code_heap_mod.CodeHeap{
            .seg = null,
            .free_list = &self.code_alloc,
            .safepoint_page = 0,
            .code_start = start,
            .code_size = size,
            .allocator = allocator,
            .remembered_sets = write_barrier_mod.CodeHeapRememberedSets.init(allocator),
        };
        self.vm.code = &self.code_heap;

        // tagBoolean returns the canonical_true special object, which is f in
        // a bare VM; install a sentinel so t and f differ.
        self.true_obj = layouts.tagFixnum(0x7472_7565);
        self.vm.vm_asm.special_objects[@intFromEnum(objects_mod.SpecialObject.canonical_true)] = self.true_obj;
        self.stack_base = self.vm.vm_asm.ctx.datastack;
    }

    fn deinit(self: *TestVM) void {
        self.vm.code = null;
        self.code_heap.deinit();
        self.code_alloc.deinit();
        std.heap.page_allocator.free(self.region);
        self.heap.deinit();
        self.vm.cards_array = null;
        self.vm.decks_array = null;
        self.vm.deinit();
    }

    fn fields(self: *TestVM) *VMAssemblyFields {
        return &self.vm.vm_asm;
    }

    fn array(self: *TestVM, values: []const Cell) Cell {
        const tagged = self.vm.allotArray(values.len, layouts.false_object) orelse @panic("allotArray failed");
        const arr: *layouts.Array = @ptrFromInt(layouts.UNTAG(tagged));
        @memcpy(arr.data()[0..values.len], values);
        return tagged;
    }

    fn bytes(self: *TestVM, data: []const u8) Cell {
        const tagged = self.vm.allotByteArray(data.len);
        const ba: *layouts.ByteArray = @ptrFromInt(layouts.UNTAG(tagged));
        @memcpy(ba.data()[0..data.len], data);
        return tagged;
    }

    fn relocations(self: *TestVM, entries: []const code_blocks.RelocationEntry) Cell {
        const tagged = self.vm.allotByteArray(entries.len * 4);
        const ba: *layouts.ByteArray = @ptrFromInt(layouts.UNTAG(tagged));
        for (entries, 0..) |e, i| {
            std.mem.writeInt(u32, ba.data()[i * 4 ..][0..4], e.value, .little);
        }
        return tagged;
    }

    fn word(self: *TestVM) Cell {
        const tagged = self.vm.allotObject(.word, @sizeOf(layouts.Word)) orelse @panic("allotObject failed");
        const w: *layouts.Word = @ptrFromInt(layouts.UNTAG(tagged));
        w.hashcode_field = layouts.tagFixnum(0);
        w.name = layouts.false_object;
        w.vocabulary = layouts.false_object;
        w.def = layouts.false_object;
        w.props = layouts.false_object;
        w.pic_def = layouts.false_object;
        w.pic_tail_def = layouts.false_object;
        w.subprimitive = layouts.false_object;
        w.entry_point = 0;
        return tagged;
    }

    fn wordPtr(tagged: Cell) *layouts.Word {
        return @ptrFromInt(layouts.UNTAG(tagged));
    }

    // Optimized-code payload as modify-code-heap expects it:
    // { parameters literals relocation labels code frame-size }
    fn payload(self: *TestVM, literals: Cell, relocation: Cell, labels: Cell, code_len: usize, frame_size: Fixnum) Cell {
        const code = self.vm.allotByteArray(code_len);
        return self.array(&.{ layouts.false_object, literals, relocation, labels, code, layouts.tagFixnum(frame_size) });
    }

    fn modifyCodeHeap(self: *TestVM, alist: Cell, update_existing: bool, reset_caches: bool) void {
        self.vm.push(alist);
        self.vm.push(if (update_existing) self.true_obj else layouts.false_object);
        self.vm.push(if (reset_caches) self.true_obj else layouts.false_object);
        primitive_modify_code_heap(self.fields());
    }

    fn blockOf(self: *TestVM, word_cell: Cell) *CodeBlock {
        const w = wordPtr(word_cell);
        return self.code_heap.codeBlockForAddress(w.entry_point) orelse @panic("word has no code block");
    }

    fn expectStackBalanced(self: *TestVM) !void {
        try testing.expectEqual(self.stack_base, self.vm.vm_asm.ctx.datastack);
    }
};

test "modify_code_heap installs optimized code, relocations and label fixups" {
    var t: TestVM = undefined;
    try t.init();
    defer t.deinit();

    const w = t.word();
    const literals = t.array(&.{ layouts.tagFixnum(42), layouts.tagFixnum(0x1234), layouts.tagFixnum(8) });
    const reloc = t.relocations(&.{
        code_blocks.RelocationEntry.init(.literal, .absolute_cell, 8),
        code_blocks.RelocationEntry.init(.this, .absolute_cell, 16),
        code_blocks.RelocationEntry.init(.untagged, .absolute_2, 18),
        code_blocks.RelocationEntry.init(.here, .relative, 24),
        code_blocks.RelocationEntry.init(.cards_offset, .absolute_cell, 32),
    });
    // One label fixup: a relative 32-bit field ending at offset 40 that must
    // point at offset 4 of the block.
    const labels = t.array(&.{ layouts.tagFixnum(@intFromEnum(code_blocks.RelocationClass.relative)), layouts.tagFixnum(40), layouts.tagFixnum(4) });
    const pair = t.array(&.{ w, t.payload(literals, reloc, labels, 40, 32) });
    const alist = t.array(&.{pair});

    t.modifyCodeHeap(alist, false, false);
    try t.expectStackBalanced();

    const word = TestVM.wordPtr(w);
    try testing.expect(word.entry_point != 0);
    const block = t.blockOf(w);
    try testing.expectEqual(word.entry_point, block.entryPoint());
    try testing.expectEqual(w, block.owner);
    try testing.expectEqual(code_blocks.CodeBlockType.optimized, block.blockType());
    try testing.expectEqual(@as(Cell, 32), block.stackFrameSize());
    try testing.expectEqual(@as(Cell, @sizeOf(CodeBlock) + 48), block.size());
    try testing.expectEqual(reloc, block.relocation);
    try testing.expectEqual(layouts.false_object, block.parameters);

    // Relocations were applied once every entry point was set.
    const entry = block.entryPoint();
    const cells: [*]const Cell = @ptrFromInt(entry);
    try testing.expectEqual(layouts.tagFixnum(42), cells[0]);
    try testing.expectEqual(entry, cells[1]);
    try testing.expectEqual(@as(u16, 0x1234), @as(*align(1) const u16, @ptrFromInt(entry + 16)).*);
    try testing.expectEqual(@as(i32, 8), @as(*align(1) const i32, @ptrFromInt(entry + 20)).*);
    try testing.expectEqual(t.vm.vm_asm.cards_offset, cells[3]);
    // The label fixup: (entry + 4) - (entry + 40).
    try testing.expectEqual(@as(i32, -36), @as(*align(1) const i32, @ptrFromInt(entry + 36)).*);

    // Bookkeeping: initialized, tracked, scannable for literals, remembered.
    try testing.expectEqual(@as(usize, 0), t.code_heap.uninitialized_blocks.count());
    try testing.expect(t.code_heap.blockHasLiterals(block));
    try testing.expect(!t.code_heap.blockHasCodePointers(block));
    try testing.expect(t.code_heap.remembered_sets.hasAny());

    // word-optimized? sees the optimized block.
    t.vm.push(w);
    primitive_word_optimized_p(t.fields());
    try testing.expectEqual(t.true_obj, t.vm.pop());
    try t.expectStackBalanced();

    // code-blocks lists the block's six fields.
    primitive_code_blocks(t.fields());
    const listing = t.vm.pop();
    try testing.expect(layouts.hasTag(listing, .array));
    const arr: *const layouts.Array = @ptrFromInt(layouts.UNTAG(listing));
    try testing.expectEqual(@as(Cell, 6), arr.getCapacity());
    try testing.expectEqual(w, arr.data()[0]);
    try testing.expectEqual(layouts.false_object, arr.data()[1]);
    try testing.expectEqual(reloc, arr.data()[2]);
    try testing.expectEqual(layouts.tagFixnum(1), arr.data()[3]);
    try testing.expectEqual(layouts.tagFixnum(@intCast(block.size())), arr.data()[4]);
    try testing.expectEqual(entry, arr.data()[5]);
    try t.expectStackBalanced();

    // An empty compilation unit is a no-op.
    t.modifyCodeHeap(t.array(&.{}), true, true);
    try t.expectStackBalanced();
    try testing.expectEqual(word.entry_point, entry);
}

test "modify_code_heap with update-existing-words repoints callers" {
    var t: TestVM = undefined;
    try t.init();
    defer t.deinit();

    // Compile W with trivial code.
    const w = t.word();
    const empty_reloc = t.vm.allotByteArray(0);
    t.modifyCodeHeap(t.array(&.{t.array(&.{ w, t.payload(t.array(&.{}), empty_reloc, layouts.false_object, 16, 0) })}), false, false);
    const w_entry_1 = TestVM.wordPtr(w).entry_point;
    try testing.expect(w_entry_1 != 0);
    // An empty relocation byte array is normalized to f.
    try testing.expectEqual(layouts.false_object, t.blockOf(w).relocation);

    // Compile V, which calls W through an absolute entry-point operand.
    const v = t.word();
    const v_reloc = t.relocations(&.{code_blocks.RelocationEntry.init(.entry_point, .absolute_cell, 8)});
    t.modifyCodeHeap(t.array(&.{t.array(&.{ v, t.payload(t.array(&.{w}), v_reloc, layouts.false_object, 16, 0) })}), false, false);
    const v_block = t.blockOf(v);
    const v_cells: [*]const Cell = @ptrFromInt(v_block.entryPoint());
    try testing.expectEqual(w_entry_1, v_cells[0]);
    try testing.expect(t.code_heap.blockHasCodePointers(v_block));

    // Recompile W with update-existing-words: V's call site follows.
    t.modifyCodeHeap(t.array(&.{t.array(&.{ w, t.payload(t.array(&.{}), empty_reloc, layouts.false_object, 24, 16) })}), true, false);
    const w_entry_2 = TestVM.wordPtr(w).entry_point;
    try testing.expect(w_entry_2 != w_entry_1);
    try testing.expectEqual(w_entry_2, v_cells[0]);
    try testing.expectEqual(@as(usize, 0), t.code_heap.uninitialized_blocks.count());
    try t.expectStackBalanced();

    // Without update-existing-words a recompile leaves callers alone.
    t.modifyCodeHeap(t.array(&.{t.array(&.{ w, t.payload(t.array(&.{}), empty_reloc, layouts.false_object, 16, 0) })}), false, false);
    const w_entry_3 = TestVM.wordPtr(w).entry_point;
    try testing.expect(w_entry_3 != w_entry_2);
    try testing.expectEqual(w_entry_2, v_cells[0]);
    try t.expectStackBalanced();

    // Every compiled block is still tracked.
    t.code_heap.flushPending();
    try testing.expectEqual(@as(usize, 4), t.code_heap.all_blocks_sorted.items.len);
    t.code_heap.verifyAllBlocksSet();
}

test "array_to_quotation and quotation_compiled_p" {
    var t: TestVM = undefined;
    try t.init();
    defer t.deinit();

    const arr = t.array(&.{ layouts.tagFixnum(1), layouts.tagFixnum(2) });
    t.vm.push(arr);
    primitive_array_to_quotation(t.fields());
    const quot_cell = t.vm.pop();
    try testing.expect(layouts.hasTag(quot_cell, .quotation));
    const quot: *layouts.Quotation = @ptrFromInt(layouts.UNTAG(quot_cell));
    try testing.expectEqual(arr, quot.array);
    try testing.expectEqual(layouts.false_object, quot.cached_effect);
    try testing.expectEqual(layouts.false_object, quot.cache_counter);
    // No lazy-jit-compile word is installed, so the stub entry point is 0.
    try testing.expectEqual(t.vm.lazyJitCompileEntryPoint(), quot.entry_point);

    t.vm.push(quot_cell);
    primitive_quotation_compiled_p(t.fields());
    try testing.expectEqual(layouts.false_object, t.vm.pop());

    quot.entry_point = 0x1000;
    t.vm.push(quot_cell);
    primitive_quotation_compiled_p(t.fields());
    try testing.expectEqual(t.true_obj, t.vm.pop());

    // A quotation whose entry point is the lazy stub is not compiled.
    const lazy_word = t.word();
    TestVM.wordPtr(lazy_word).entry_point = 0x1000;
    t.vm.vm_asm.special_objects[@intFromEnum(objects_mod.SpecialObject.lazy_jit_compile_word)] = lazy_word;
    try testing.expectEqual(@as(Cell, 0x1000), t.vm.lazyJitCompileEntryPoint());
    t.vm.push(quot_cell);
    primitive_quotation_compiled_p(t.fields());
    try testing.expectEqual(layouts.false_object, t.vm.pop());

    // Non-quotations are never compiled.
    t.vm.push(arr);
    primitive_quotation_compiled_p(t.fields());
    try testing.expectEqual(layouts.false_object, t.vm.pop());
    try t.expectStackBalanced();
}

test "objectClass, lookup_method and tuple echelon dispatch" {
    var t: TestVM = undefined;
    try t.init();
    defer t.deinit();

    const fixnum_method = t.word();
    const array_method = t.word();
    const hashed_method = t.word();
    const direct_method = t.word();
    const superclass = t.word();

    // Tuple layout: klass, size, echelon, then (superclass, hashcode) pairs.
    // The hashcode picks bucket 6 & 3 = 2 of a 4-bucket table.
    const layout = t.array(&.{ layouts.false_object, layouts.tagFixnum(0), layouts.tagFixnum(0), superclass, layouts.tagFixnum(6) });
    const tuple_cell = t.vm.allotObject(.tuple, @sizeOf(layouts.Tuple)) orelse unreachable;
    const tuple: *layouts.Tuple = @ptrFromInt(layouts.UNTAG(tuple_cell));
    tuple.layout = layout;

    try testing.expectEqual(layouts.tagFixnum(0), objectClass(layouts.tagFixnum(99)));
    try testing.expectEqual(layouts.tagFixnum(@intFromEnum(layouts.TypeTag.array)), objectClass(layout));
    try testing.expectEqual(layout, objectClass(tuple_cell));

    // A method table indexed by type tag; the tuple slot holds echelons.
    var methods_values = [_]Cell{layouts.false_object} ** 16;
    methods_values[@intFromEnum(layouts.TypeTag.fixnum)] = fixnum_method;
    methods_values[@intFromEnum(layouts.TypeTag.array)] = array_method;
    const alist = t.array(&.{ superclass, hashed_method });
    const buckets = t.array(&.{ layouts.false_object, layouts.false_object, alist, layouts.false_object });
    const echelons = t.array(&.{buckets});
    methods_values[@intFromEnum(layouts.TypeTag.tuple)] = echelons;
    const methods = t.array(&methods_values);

    const fix = lookupMethodAndClass(layouts.tagFixnum(5), methods);
    try testing.expectEqual(fixnum_method, fix.method);
    try testing.expectEqual(layouts.tagFixnum(0), fix.klass);
    try testing.expectEqual(array_method, lookupMethod(layout, methods));

    const tup = lookupMethodAndClass(tuple_cell, methods);
    try testing.expectEqual(hashed_method, tup.method);
    try testing.expectEqual(layout, tup.klass);

    // A bucket holding a method directly, without an alist.
    const direct_buckets = t.array(&.{ layouts.false_object, layouts.false_object, direct_method, layouts.false_object });
    const echelons_arr: *layouts.Array = @ptrFromInt(layouts.UNTAG(echelons));
    echelons_arr.data()[0] = direct_buckets;
    try testing.expectEqual(direct_method, lookupMethod(tuple_cell, methods));

    // An echelon slot holding a word applies to every class of that echelon.
    echelons_arr.data()[0] = array_method;
    try testing.expectEqual(array_method, lookupMethod(tuple_cell, methods));

    // A layout deeper than the table walks down to the last echelon, and an
    // f echelon is skipped.
    const layout_arr: *layouts.Array = @ptrFromInt(layouts.UNTAG(layout));
    layout_arr.data()[2] = layouts.tagFixnum(3);
    const two_echelons = t.array(&.{ buckets, layouts.false_object });
    methods_values[@intFromEnum(layouts.TypeTag.tuple)] = two_echelons;
    const methods2 = t.array(&methods_values);
    try testing.expectEqual(hashed_method, lookupMethod(tuple_cell, methods2));

    // A non-array tuple slot is used as the method for all tuples.
    methods_values[@intFromEnum(layouts.TypeTag.tuple)] = direct_method;
    const methods3 = t.array(&methods_values);
    try testing.expectEqual(direct_method, lookupMethod(tuple_cell, methods3));

    // The primitive pops object and methods and pushes the method.
    t.vm.push(tuple_cell);
    t.vm.push(methods2);
    primitive_lookup_method(t.fields());
    try testing.expectEqual(hashed_method, t.vm.pop());
    try t.expectStackBalanced();
}

test "mega_cache_miss looks up and caches the method" {
    var t: TestVM = undefined;
    try t.init();
    defer t.deinit();

    const fixnum_method = t.word();
    const superclass = t.word();
    const tuple_method = t.word();
    const layout = t.array(&.{ layouts.false_object, layouts.tagFixnum(0), layouts.tagFixnum(0), superclass, layouts.tagFixnum(1) });
    const tuple_cell = t.vm.allotObject(.tuple, @sizeOf(layouts.Tuple)) orelse unreachable;
    @as(*layouts.Tuple, @ptrFromInt(layouts.UNTAG(tuple_cell))).layout = layout;

    var methods_values = [_]Cell{layouts.false_object} ** 16;
    methods_values[@intFromEnum(layouts.TypeTag.fixnum)] = fixnum_method;
    const buckets = t.array(&.{ layouts.false_object, t.array(&.{ superclass, tuple_method }) });
    methods_values[@intFromEnum(layouts.TypeTag.tuple)] = t.array(&.{buckets});
    const methods = t.array(&methods_values);

    // A 4-entry (klass, method) cache.
    var cache_values = [_]Cell{layouts.false_object} ** 8;
    const cache = t.array(&cache_values);
    const cache_arr: *const layouts.Array = @ptrFromInt(layouts.UNTAG(cache));
    const misses_before = t.vm.dispatch_stats.megamorphic_cache_misses;

    // The dispatched object is `index` cells below the top of the stack
    // after the three arguments are popped.
    t.vm.push(layouts.tagFixnum(5));
    t.vm.push(methods);
    t.vm.push(layouts.tagFixnum(0));
    t.vm.push(cache);
    primitive_mega_cache_miss(t.fields());
    try testing.expectEqual(fixnum_method, t.vm.pop());
    try testing.expectEqual(layouts.tagFixnum(5), t.vm.pop());
    try testing.expectEqual(misses_before + 1, t.vm.dispatch_stats.megamorphic_cache_misses);
    // klass fixnum-tag 0 hashes to slot 0.
    try testing.expectEqual(layouts.tagFixnum(0), cache_arr.data()[0]);
    try testing.expectEqual(fixnum_method, cache_arr.data()[1]);

    // A tuple with something under it on the stack: index 1.
    t.vm.push(tuple_cell);
    t.vm.push(layouts.tagFixnum(7));
    t.vm.push(methods);
    t.vm.push(layouts.tagFixnum(1));
    t.vm.push(cache);
    primitive_mega_cache_miss(t.fields());
    try testing.expectEqual(tuple_method, t.vm.pop());
    try testing.expectEqual(layouts.tagFixnum(7), t.vm.pop());
    try testing.expectEqual(tuple_cell, t.vm.pop());
    const slot = ((layout >> layouts.tag_bits) & 3) << 1;
    try testing.expectEqual(layout, cache_arr.data()[slot]);
    try testing.expectEqual(tuple_method, cache_arr.data()[slot + 1]);
    try testing.expectEqual(misses_before + 2, t.vm.dispatch_stats.megamorphic_cache_misses);
    try t.expectStackBalanced();
}
