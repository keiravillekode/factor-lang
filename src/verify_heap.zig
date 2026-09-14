// verify_heap.zig - Post-collection heap verifier (-verify-heap[=N]).
//
// A fuzzing/debugging aid, off by default. The collector relies on invariants
// that nothing checks until a later collection trips over their violation —
// by which time the culprit is long gone. Run once a collection has fully
// finished (GarbageCollector.afterCollection), this checks them directly:
//
//   * the nursery is empty, and nothing points into the aging semispace;
//   * aging [start, here) and tenured tile exactly into well-formed objects
//     (and, in tenured, free blocks): no forwarding pointers, valid header
//     types, fixnum lengths, sizes inside the space;
//   * every tagged pointer — object slots, callstack-object spill slots,
//     roots (special objects, data_roots, context objects, data/retain
//     stacks, live callstack spill slots, callback owners, uninitialized
//     code-block literals, profiler samples), code-block header fields and
//     embedded literals — points at the start of an allocated object in
//     tenured or aging whose header type matches the pointer's tag;
//   * word/quotation entry points into the code heap land in a live block;
//   * card marking: a tenured slot referencing aging has its card and deck
//     aging bits set (nursery collections scan only marked cards);
//   * code remembered sets: a code block referencing aging is in the aging
//     set, every set bit has a dirty-list entry (scans read only the list),
//     and a block with literal relocations has its scan flag set;
//   * object-start maps: every recorded start is an object or free-block
//     boundary, and aging records nothing at or past `here` (a stale smaller
//     offset there would survive recordObjectStart and misdirect a later
//     card scan).
//
// Unreachable-but-unswept objects are checked too, deliberately: card scans
// visit every object on a dirty card, live or not, so they must stay
// well-formed between full collections.
//
// Violations print as "verify-heap: <check>: <details>", where <check> is
// address-free so fuzzers can deduplicate on it; then the VM panics.

const std = @import("std");
const code_blocks = @import("code_blocks.zig");
const code_heap_mod = @import("code_heap.zig");
const contexts = @import("contexts.zig");
const data_heap_mod = @import("data_heap.zig");
const free_list = @import("free_list.zig");
const gc_mod = @import("gc.zig");
const layouts = @import("layouts.zig");
const object_start_map = @import("object_start_map.zig");
const slot_visitor = @import("slot_visitor.zig");
const vm_mod = @import("vm.zig");

const Cell = layouts.Cell;
const CodeBlock = code_blocks.CodeBlock;
const TypeTag = layouts.TypeTag;

const max_reports = 20;

pub fn verify(gc: *gc_mod.GarbageCollector) void {
    const heap = gc.heap;
    const bit_count: usize = @intCast(heap.segment.size / layouts.data_alignment);
    var starts = std.DynamicBitSet.initEmpty(gc.allocator, bit_count) catch {
        std.debug.print("verify-heap: skipped, out of memory for object bitmaps\n", .{});
        return;
    };
    defer starts.deinit();
    var boundaries = std.DynamicBitSet.initEmpty(gc.allocator, bit_count) catch {
        std.debug.print("verify-heap: skipped, out of memory for object bitmaps\n", .{});
        return;
    };
    defer boundaries.deinit();

    gc.verifications += 1;
    var v = Verifier{
        .gc = gc,
        .vm = gc.vm,
        .heap = heap,
        .base = heap.segment.start,
        .starts = &starts,
        .boundaries = &boundaries,
    };

    // The aging semispace is deliberately not required to be empty:
    // collectAging flips by hand and resets only the new to-space, leaving the
    // old from-space (forwarding pointers, dead objects) until the next flip
    // resets it. It only matters that nothing points into it (checkPointer).
    const nursery = &gc.vm.vm_asm.nursery;
    if (nursery.here != nursery.start) {
        v.fail("nursery-not-empty", "here 0x{x} start 0x{x}", .{ nursery.here, nursery.start });
    }

    v.walkSpace("aging", heap.aging.start, heap.aging.here, false);
    v.walkSpace("tenured", heap.tenured.start, heap.tenured.end, true);
    v.checkObjectStartMap("aging", &heap.aging.object_start, heap.aging.here);
    v.checkObjectStartMap("tenured", &heap.tenured.object_start, heap.tenured.end);
    v.checkObjects();
    v.checkRoots();
    v.checkCodeHeap();

    if (v.failures != 0) {
        std.debug.print(
            "verify-heap: {d} violation(s) in verification #{d} (collections: nursery {d}, aging {d}, full {d})\n",
            .{ v.failures, gc.verifications, heap.nursery_collections, heap.aging_collections, heap.full_collections },
        );
        @panic("verify-heap: heap verification failed");
    }
}

const Verifier = struct {
    gc: *gc_mod.GarbageCollector,
    vm: *vm_mod.FactorVM,
    heap: *data_heap_mod.DataHeap,
    base: Cell,
    // Indexed by (address - base) / data_alignment.
    starts: *std.DynamicBitSet, // allocated objects
    boundaries: *std.DynamicBitSet, // allocated objects and free blocks
    failures: usize = 0,

    fn fail(self: *Verifier, comptime check: []const u8, comptime fmt: []const u8, args: anytype) void {
        self.failures += 1;
        if (self.failures <= max_reports) {
            std.debug.print("verify-heap: " ++ check ++ ": " ++ fmt ++ "\n", args);
        }
    }

    fn bitIndex(self: *const Verifier, addr: Cell) usize {
        return @intCast((addr - self.base) / layouts.data_alignment);
    }

    fn inOldSpace(self: *const Verifier, addr: Cell) bool {
        return self.heap.tenured.contains(addr) or
            (addr >= self.heap.aging.start and addr < self.heap.aging.here);
    }

    fn validLength(self: *const Verifier, cell: Cell) bool {
        if (!layouts.hasTag(cell, .fixnum)) return false;
        const n = layouts.untagFixnum(cell);
        return n >= 0 and @as(Cell, @intCast(n)) <= self.heap.segment.size;
    }

    // --- Pass 1: tile the spaces, recording object and free-block starts ---

    fn walkSpace(self: *Verifier, comptime space: []const u8, start: Cell, end: Cell, allow_free: bool) void {
        var addr = start;
        while (addr < end) {
            const header = @as(*const Cell, @ptrFromInt(addr)).*;
            if ((header & 1) != 0) {
                const size = header & ~@as(Cell, 7);
                if (!allow_free) {
                    self.fail("free-block-in-" ++ space, "at 0x{x} size {d}", .{ addr, size });
                    return;
                }
                if (size == 0 or size % layouts.data_alignment != 0 or size > end - addr) {
                    self.fail("bad-free-block-in-" ++ space, "at 0x{x} header 0x{x}", .{ addr, header });
                    return;
                }
                self.boundaries.set(self.bitIndex(addr));
                addr += size;
                continue;
            }
            // initForImageLoad leaves a tail smaller than a free block untiled.
            if (header == 0 and allow_free and end - addr < free_list.min_block_size) return;

            const size = self.objectSize(space, addr, header) orelse return;
            if (size > end - addr) {
                self.fail("object-overruns-" ++ space, "at 0x{x} header 0x{x} size {d}, space end 0x{x}", .{ addr, header, size, end });
                return;
            }
            self.starts.set(self.bitIndex(addr));
            self.boundaries.set(self.bitIndex(addr));
            addr += size;
        }
    }

    fn objectSize(self: *Verifier, comptime space: []const u8, addr: Cell, header: Cell) ?Cell {
        if ((header & 2) != 0) {
            self.fail("forwarding-pointer-in-" ++ space, "at 0x{x} -> 0x{x}", .{ addr, layouts.UNTAG(header) });
            return null;
        }
        const raw_type = (header >> 2) & layouts.tag_mask;
        if (raw_type <= @intFromEnum(TypeTag.f) or raw_type > @intFromEnum(TypeTag.dll)) {
            self.fail("bad-header-type-in-" ++ space, "at 0x{x} header 0x{x}", .{ addr, header });
            return null;
        }
        const obj_type: TypeTag = @enumFromInt(@as(u4, @intCast(raw_type)));

        // objectVisitInfoFromAddress panics on a non-fixnum length; check first
        // so the report says which object.
        const length_cell: ?Cell = switch (obj_type) {
            .array => @as(*const layouts.Array, @ptrFromInt(addr)).capacity,
            .byte_array => @as(*const layouts.ByteArray, @ptrFromInt(addr)).capacity,
            .bignum => @as(*const layouts.Bignum, @ptrFromInt(addr)).capacity,
            .string => @as(*const layouts.String, @ptrFromInt(addr)).length,
            .callstack => @as(*const layouts.Callstack, @ptrFromInt(addr)).length,
            .tuple => self.tupleLayoutSize(space, addr) orelse return null,
            else => null,
        };
        if (length_cell) |cell| {
            if (!self.validLength(cell)) {
                self.fail("bad-length-in-" ++ space, "{s} at 0x{x} length cell 0x{x}", .{ @tagName(obj_type), addr, cell });
                return null;
            }
        }

        const size = layouts.objectVisitInfoFromAddress(addr).size;
        if (size == 0 or size % layouts.data_alignment != 0) {
            self.fail("bad-object-size-in-" ++ space, "{s} at 0x{x} size {d}", .{ @tagName(obj_type), addr, size });
            return null;
        }
        return size;
    }

    // The tuple's size lives in its layout, which must be checked before
    // objectVisitInfoFromAddress dereferences it.
    fn tupleLayoutSize(self: *Verifier, comptime space: []const u8, addr: Cell) ?Cell {
        const layout_cell = @as(*const layouts.Tuple, @ptrFromInt(addr)).layout;
        const layout_addr = layouts.UNTAG(layout_cell);
        if (!layouts.hasTag(layout_cell, .array) or !self.inOldSpace(layout_addr)) {
            self.fail("bad-tuple-layout-in-" ++ space, "tuple at 0x{x} layout 0x{x}", .{ addr, layout_cell });
            return null;
        }
        const layout_header = @as(*const Cell, @ptrFromInt(layout_addr)).*;
        if ((layout_header & 3) != 0 or ((layout_header >> 2) & layouts.tag_mask) != @intFromEnum(TypeTag.array)) {
            self.fail("bad-tuple-layout-header-in-" ++ space, "tuple at 0x{x} layout 0x{x} header 0x{x}", .{ addr, layout_cell, layout_header });
            return null;
        }
        return @as(*const layouts.TupleLayout, @ptrFromInt(layout_addr)).size;
    }

    fn checkObjectStartMap(self: *Verifier, comptime space: []const u8, osm: *const object_start_map.ObjectStartMap, end: Cell) void {
        for (osm.entries, 0..) |entry, card| {
            if (entry == object_start_map.invalid_offset) continue;
            const addr = osm.start + card * vm_mod.card_size + entry;
            if (addr >= end) {
                self.fail("stale-object-start-entry-in-" ++ space, "card {d} records 0x{x}, allocated end 0x{x}", .{ card, addr, end });
            } else if (addr < self.base or !self.boundaries.isSet(self.bitIndex(addr))) {
                self.fail("object-start-entry-off-boundary-in-" ++ space, "card {d} records 0x{x}", .{ card, addr });
            }
        }
    }

    // --- Pass 2: every pointer ---

    fn checkPointer(self: *Verifier, value: Cell, what: []const u8, holder: Cell, slot_addr: Cell) bool {
        const heap = self.heap;
        const addr = layouts.UNTAG(value);
        const fmt = "{s} slot 0x{x} of 0x{x} holds 0x{x}";
        const args = .{ what, slot_addr, holder, value };

        if (!heap.contains(addr)) {
            self.fail("pointer-outside-data-heap", fmt, args);
            return false;
        }
        if (addr >= heap.nursery.start and addr < heap.nursery.end) {
            self.fail("pointer-into-nursery", fmt, args);
            return false;
        }
        if (heap.aging_semispace.contains(addr)) {
            self.fail("pointer-into-aging-semispace", fmt, args);
            return false;
        }
        if (!self.inOldSpace(addr)) {
            self.fail("pointer-into-unallocated-space", fmt, args);
            return false;
        }
        const index = self.bitIndex(addr);
        if (!self.starts.isSet(index)) {
            if (self.boundaries.isSet(index)) {
                self.fail("pointer-to-free-block", fmt, args);
            } else {
                self.fail("pointer-not-at-object-start", fmt, args);
            }
            return false;
        }
        const header_type = (@as(*const Cell, @ptrFromInt(addr)).* >> 2) & layouts.tag_mask;
        if (header_type != layouts.TAG(value)) {
            self.fail("pointer-tag-mismatches-header", fmt ++ ", header type {d}", .{ what, slot_addr, holder, value, header_type });
            return false;
        }
        return true;
    }

    fn checkAgingCard(self: *Verifier, what: []const u8, holder: Cell, slot_addr: Cell, value: Cell) void {
        const card: *const u8 = @ptrFromInt(self.vm.vm_asm.cards_offset +% (slot_addr >> @intCast(vm_mod.card_bits)));
        const deck: *const u8 = @ptrFromInt(self.vm.vm_asm.decks_offset +% (slot_addr >> @intCast(vm_mod.deck_bits)));
        if ((card.* & vm_mod.card_points_to_aging) == 0) {
            self.fail("unmarked-card-for-tenured-to-aging-pointer", "{s} slot 0x{x} of 0x{x} holds 0x{x}, card 0x{x}", .{ what, slot_addr, holder, value, card.* });
        } else if ((deck.* & vm_mod.card_points_to_aging) == 0) {
            self.fail("unmarked-deck-for-tenured-to-aging-pointer", "{s} slot 0x{x} of 0x{x} holds 0x{x}, deck 0x{x}", .{ what, slot_addr, holder, value, deck.* });
        }
    }

    fn checkEntryPoint(self: *Verifier, entry_point: Cell, holder: Cell) void {
        const code = self.vm.code orelse return;
        if (entry_point < code.code_start or entry_point >= code.code_start + code.code_size) return;
        const block = code.codeBlockForAddress(entry_point) orelse {
            self.fail("entry-point-outside-code-blocks", "holder 0x{x} entry point 0x{x}", .{ holder, entry_point });
            return;
        };
        if (block.isFree()) {
            self.fail("entry-point-into-free-code-block", "holder 0x{x} entry point 0x{x}", .{ holder, entry_point });
        }
    }

    fn checkObjects(self: *Verifier) void {
        var it = self.starts.iterator(.{});
        while (it.next()) |index| {
            const addr = self.base + index * layouts.data_alignment;
            const info = layouts.objectVisitInfoFromAddress(addr);
            var check = SlotCheck{
                .v = self,
                .holder = addr,
                .holder_tenured = self.heap.tenured.contains(addr),
                .what = @tagName(info.type),
            };
            const slots: [*]Cell = @ptrFromInt(addr + @sizeOf(Cell));
            for (0..info.slot_count) |i| check.visitSlot(&slots[i]);

            switch (info.type) {
                .quotation => self.checkEntryPoint(@as(*const layouts.Quotation, @ptrFromInt(addr)).entry_point, addr),
                .word => self.checkEntryPoint(@as(*const layouts.Word, @ptrFromInt(addr)).entry_point, addr),
                .callstack => if (self.vm.code) |code| {
                    check.what = "callstack object frame";
                    slot_visitor.visitCallstackObjectRoots(SlotCheck, &check, code, @ptrFromInt(addr));
                },
                else => {},
            }
        }
    }

    fn checkRoots(self: *Verifier) void {
        const vm = self.vm;
        var check = SlotCheck{ .v = self, .holder = 0, .holder_tenured = false, .what = "special object" };
        for (&vm.vm_asm.special_objects) |*slot| check.visitSlot(slot);

        check.what = "data root";
        for (vm.data_roots.items) |root_ptr| check.visitSlot(root_ptr);

        for (vm.active_contexts.items) |ctx| self.checkContext(ctx);
        if (!vm.vm_asm.ctx.isActive()) self.checkContext(vm.vm_asm.ctx);

        if (vm.callbacks) |callbacks| callbacks.iterateOwnersWithCtx(*Verifier, checkCallbackOwner, self);

        if (vm.code) |code| {
            check.what = "uninitialized code block literals";
            var it = code.uninitialized_blocks.iterator();
            while (it.next()) |entry| check.visitSlot(entry.value_ptr);
        }

        check.what = "profiler sample thread";
        for (vm.profiling_samples.items) |*sample| check.visitSlot(&sample.thread);
    }

    fn checkCallbackOwner(slot: *Cell, self: *Verifier) void {
        var check = SlotCheck{ .v = self, .holder = 0, .holder_tenured = false, .what = "callback owner" };
        check.visitSlot(slot);
    }

    fn checkContext(self: *Verifier, ctx: *contexts.Context) void {
        var check = SlotCheck{ .v = self, .holder = 0, .holder_tenured = false, .what = "context object" };
        for (&ctx.context_objects) |*slot| check.visitSlot(slot);

        // Same ranges visitContext copies: [seg.start, top] inclusive.
        check.what = "datastack";
        if (ctx.datastack_seg) |seg| checkStack(&check, seg.start, ctx.datastack);
        check.what = "retainstack";
        if (ctx.retainstack_seg) |seg| checkStack(&check, seg.start, ctx.retainstack);

        if (self.vm.code) |code| {
            check.what = "callstack spill slot";
            slot_visitor.visitLiveCallstackRoots(SlotCheck, &check, code, ctx.callstack_top, ctx.callstack_bottom);
        }
    }

    fn checkStack(check: *SlotCheck, start: Cell, top: Cell) void {
        var ptr = start;
        while (ptr <= top) : (ptr += @sizeOf(Cell)) {
            check.visitSlot(@ptrFromInt(ptr));
        }
    }

    // --- Code heap ---

    fn checkCodeHeap(self: *Verifier) void {
        const code = self.vm.code orelse return;
        code.flushPending();

        const sets = &code.remembered_sets;
        if (sets.points_to_nursery) |*bits| self.checkDirtyList("nursery", code, bits, sets.nurseryDirtyBlocks());
        if (sets.points_to_aging) |*bits| self.checkDirtyList("aging", code, bits, sets.agingDirtyBlocks());

        const has_uninitialized = code.uninitialized_blocks.count() != 0;
        var previous_end: Cell = 0;
        for (code.all_blocks_sorted.items) |block_addr| {
            const block: *CodeBlock = @ptrFromInt(block_addr);
            if (block_addr < previous_end) {
                self.fail("overlapping-code-blocks", "block 0x{x} starts before previous end 0x{x}", .{ block_addr, previous_end });
            }
            if (block.isFree()) {
                self.fail("free-block-in-code-index", "block 0x{x}", .{block_addr});
                continue;
            }
            previous_end = block_addr + block.size();

            var check = CodeCheck{ .v = self, .block = block_addr };
            _ = check.value(block.owner, "code block owner");
            _ = check.value(block.parameters, "code block parameters");
            const relocation_ok = check.value(block.relocation, "code block relocation");
            // Operands of uninitialized blocks are never visited (not yet relocated).
            if (relocation_ok and !(has_uninitialized and code.isUninitializedAddress(block_addr))) {
                self.checkEmbeddedLiterals(code, block, &check);
            }

            if (check.refs_aging) {
                const in_aging_set = if (sets.points_to_aging) |*bits|
                    bits.isSet(@intCast((block_addr - sets.code_start) / layouts.data_alignment))
                else
                    false;
                if (!in_aging_set) {
                    self.fail("code-block-referencing-aging-not-in-remembered-set", "block 0x{x} owner 0x{x}", .{ block_addr, block.owner });
                }
            }
        }
    }

    // GC scans only the dirty lists, so a set bit without an entry is a missed root.
    fn checkDirtyList(self: *Verifier, comptime name: []const u8, code: *code_heap_mod.CodeHeap, bits: *const std.DynamicBitSet, dirty: []const usize) void {
        var listed = std.DynamicBitSet.initEmpty(self.gc.allocator, bits.capacity()) catch return;
        defer listed.deinit();
        for (dirty) |index| {
            if (index >= listed.capacity()) {
                self.fail("dirty-index-out-of-range-" ++ name, "index {d}, capacity {d}", .{ index, listed.capacity() });
                continue;
            }
            listed.set(index);
        }
        var it = bits.iterator(.{});
        while (it.next()) |index| {
            if (!listed.isSet(index)) {
                self.fail("remembered-bit-without-dirty-entry-" ++ name, "block 0x{x}", .{code.code_start + index * layouts.data_alignment});
            }
        }
    }

    // Mirrors card_scan.scanEmbeddedLiterals' operand walk.
    fn checkEmbeddedLiterals(self: *Verifier, code: *code_heap_mod.CodeHeap, block: *CodeBlock, check: *CodeCheck) void {
        if (!layouts.hasTag(block.relocation, .byte_array)) return;
        const reloc_ba: *const layouts.ByteArray = @ptrFromInt(layouts.UNTAG(block.relocation));
        const reloc_count = layouts.untagFixnumUnsigned(reloc_ba.capacity) / @sizeOf(code_blocks.RelocationEntry);
        const reloc_data = reloc_ba.data();

        var param_index: Cell = 0;
        var has_literal = false;
        for (0..reloc_count) |i| {
            const entry_ptr: *const code_blocks.RelocationEntry = @ptrCast(@alignCast(reloc_data + i * @sizeOf(code_blocks.RelocationEntry)));
            const entry = entry_ptr.*;
            switch (entry.getType()) {
                .literal => {
                    has_literal = true;
                    const op = code_blocks.InstructionOperand.init(entry, block, param_index);
                    _ = check.value(@bitCast(op.loadValue()), "embedded literal");
                },
                .vm => param_index += 1,
                .dlsym => param_index += 2,
                else => {},
            }
        }
        if (has_literal and code.scan_literals != null and !code.blockHasLiterals(block)) {
            self.fail("literal-relocations-without-scan-flag", "block 0x{x}", .{@intFromPtr(block)});
        }
    }
};

const SlotCheck = struct {
    v: *Verifier,
    holder: Cell, // object containing the slot; 0 for roots
    holder_tenured: bool,
    what: []const u8,

    pub fn visitSlot(self: *SlotCheck, slot: *Cell) void {
        const value = slot.*;
        if (layouts.isImmediate(value)) return;
        const slot_addr = @intFromPtr(slot);
        if (!self.v.checkPointer(value, self.what, self.holder, slot_addr)) return;
        if (self.holder_tenured and self.v.heap.aging.contains(layouts.UNTAG(value))) {
            self.v.checkAgingCard(self.what, self.holder, slot_addr, value);
        }
    }
};

const CodeCheck = struct {
    v: *Verifier,
    block: Cell,
    refs_aging: bool = false,

    fn value(self: *CodeCheck, val: Cell, what: []const u8) bool {
        if (layouts.isImmediate(val)) return true;
        if (!self.v.checkPointer(val, what, self.block, 0)) return false;
        if (self.v.heap.aging.contains(layouts.UNTAG(val))) self.refs_aging = true;
        return true;
    }
};
