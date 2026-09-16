// sweep.zig - Sweep phase for full GC
// Extracted from gc.zig. Walk tenured space, find unmarked regions,
// and rebuild the free list. Also handles code heap sweeping and
// card/deck clearing.

const std = @import("std");

const free_list_mod = @import("free_list.zig");
const layouts = @import("layouts.zig");
const mark_bits = @import("mark_bits.zig");
const object_start_map = @import("object_start_map.zig");
const vm_mod = @import("vm.zig");

const Cell = layouts.Cell;
const CodeBlock = @import("code_blocks.zig").CodeBlock;
const GC = @import("gc.zig").GarbageCollector;

pub fn sweepPhase(gc: *GC) void {
    if (gc.current_event) |event| event.resetTimer();

    const tenured = &gc.heap.tenured;
    const marks = &tenured.marks;
    const osm = &tenured.object_start;

    tenured.free_list.reset();

    // Combined pass: iterate mark bits cells once for both free list
    // building AND OSM update (previously two separate passes over
    // marks.marked[]). Each 64-bit cell covers 4 OSM cards.
    const is_64 = @sizeOf(Cell) == 8;
    const cards_per_cell: usize = if (is_64) 4 else 2;

    var free_start: Cell = 0; // 0 = not in a free region

    for (0..marks.bits_size) |index| {
        const mask = marks.marked[index];
        const base_addr = marks.start + index * @bitSizeOf(Cell) * layouts.data_alignment;

        // --- OSM update (from updateForSweep) ---
        if (mask == 0) {
            const first_card = index * cards_per_cell;
            if (first_card < osm.entries.len) {
                const last = @min(first_card + cards_per_cell, osm.entries.len);
                @memset(osm.entries[first_card..last], object_start_map.invalid_offset);
            }
        } else {
            if (is_64) {
                osm.updateCardForSweep(index * 4, @intCast(mask & 0xFFFF));
                osm.updateCardForSweep(index * 4 + 1, @intCast((mask >> 16) & 0xFFFF));
                osm.updateCardForSweep(index * 4 + 2, @intCast((mask >> 32) & 0xFFFF));
                osm.updateCardForSweep(index * 4 + 3, @intCast((mask >> 48) & 0xFFFF));
            } else {
                osm.updateCardForSweep(index * 2, @intCast(mask & 0xFFFF));
                osm.updateCardForSweep(index * 2 + 1, @intCast((mask >> 16) & 0xFFFF));
            }
        }

        // --- Free list building from zero-bit runs ---
        if (mask == 0) {
            if (free_start == 0) free_start = base_addr;
            continue;
        }

        if (mask == ~@as(Cell, 0)) {
            if (free_start != 0) {
                addFreeRegion(tenured.free_list, free_start, base_addr);
                free_start = 0;
            }
            continue;
        }

        // Mixed cell — extract zero-bit runs for free regions
        free_start = extractFreeRuns(tenured.free_list, mask, base_addr, free_start);
    }

    // Close final free region at end of tenured space
    if (free_start != 0) {
        addFreeRegion(tenured.free_list, free_start, tenured.end);
    }

    tenured.free_list.sortLargeBlocks();

    resetTenuredCards(gc);

    if (gc.current_event) |event| event.endedPhase(.data_sweep);

    // Sweep code heap and invalidate code roots
    if (gc.current_event) |event| event.resetTimer();
    if (gc.vm.code) |code| {
        if (code.marks) |code_marks| {
            invalidateCodeRootsAfterSweep(gc, code_marks);
            sweepCodePhase(gc, code, code_marks);
        }
    }
    if (gc.current_event) |event| event.endedPhase(.code_sweep);
}

fn addFreeRegion(fl: *free_list_mod.FreeListAllocator, start: Cell, end_addr: Cell) void {
    const size = end_addr - start;
    if (size >= free_list_mod.min_block_size) {
        fl.addFreeBlockUnsorted(start, size);
    }
}

// Extract free (zero-bit) runs from a mixed mark bits cell and add them
// to the free list. Returns the carried-over free_start for the next cell
// (non-zero if the cell ends in a free run, 0 otherwise).
fn extractFreeRuns(
    fl: *free_list_mod.FreeListAllocator,
    mask: Cell,
    base_addr: Cell,
    free_start_in: Cell,
) Cell {
    var free_start = free_start_in;
    var pos: usize = 0;
    var in_free = free_start != 0;

    while (pos < @bitSizeOf(Cell)) {
        const shift: u6 = @truncate(pos);
        if (in_free) {
            // Find next set bit (end of free region)
            const remaining = mask >> shift;
            if (remaining == 0) return free_start; // rest of cell is free
            const next_one = @ctz(remaining);
            const end_pos = pos + next_one;
            addFreeRegion(fl, free_start, base_addr + end_pos * layouts.data_alignment);
            free_start = 0;
            in_free = false;
            pos = end_pos;
        } else {
            // Find next clear bit (start of free region)
            const remaining = (~mask) >> shift;
            if (remaining == 0) return 0; // rest of cell is marked
            const next_zero = @ctz(remaining);
            pos += next_zero;
            free_start = base_addr + pos * layouts.data_alignment;
            in_free = true;
        }
    }

    return free_start;
}

pub fn invalidateCodeRootsAfterSweep(gc: *GC, marks: *mark_bits.MarkBits) void {
    const mask: Cell = ~@as(Cell, layouts.data_alignment - 1);
    for (gc.vm.code_roots.items) |root| {
        if (!root.valid) continue;
        const block = root.value & mask;
        if (!marks.isMarked(block)) {
            root.valid = false;
        }
    }
}

pub fn sweepCodePhase(gc: *GC, code: *vm_mod.CodeHeap, marks: *mark_bits.MarkBits) void {
    _ = gc;
    code.flushPending();
    const free_list = code.free_list orelse return;

    const code_end = code.code_start + code.code_size;

    // If there are no unmarked blocks, skip rebuilding the free list.
    if (marks.nextUnmarkedBlockAfter(code.code_start) >= code_end) {
        code.clearRememberedSets();
        return;
    }

    free_list.reset();

    var current = code.code_start;
    const end = code_end;

    while (current < end) {
        current = marks.nextUnmarkedBlockAfter(current);
        if (current < end) {
            const size = marks.unmarkedBlockSize(current);
            if (size == 0) break;
            if (size >= free_list_mod.min_block_size) {
                free_list.addFreeBlockUnsorted(current, size);
            }
            current += size;
        }
    }
    free_list.sortLargeBlocks();

    // Incrementally drop dead code blocks from metadata.
    // Check upfront whether maps have entries — most are empty during sweep,
    // and skipping the per-block hash lookups saves significant time.
    const has_uninit = code.uninitialized_blocks.count() > 0;
    const has_scan_flags = code.scan_literals != null;

    var write_idx: usize = 0;
    const items = code.all_blocks_sorted.items;
    for (items) |block_addr| {
        if (marks.isMarked(block_addr)) {
            items[write_idx] = block_addr;
            write_idx += 1;
            continue;
        }

        if (has_scan_flags) code.removeScanFlagsByAddress(block_addr);
        if (has_uninit) _ = code.removeUninitializedBlock(block_addr);
    }
    code.all_blocks_sorted.items.len = write_idx;
    code.clearRememberedSets();
}

// Clear card/deck marks for tenured space
pub fn resetTenuredCards(gc: *GC) void {
    const tenured = &gc.heap.tenured;
    const cards_offset: Cell = gc.vm.vm_asm.cards_offset;
    const decks_offset: Cell = gc.vm.vm_asm.decks_offset;

    const first_card = tenured.start >> @intCast(vm_mod.card_bits);
    const last_card = (tenured.end + vm_mod.card_size - 1) >> @intCast(vm_mod.card_bits);
    const card_count = last_card - first_card;
    const card_ptr: [*]u8 = @ptrFromInt(cards_offset + first_card);
    @memset(card_ptr[0..card_count], 0);

    const first_deck = tenured.start >> @intCast(vm_mod.deck_bits);
    const last_deck = (tenured.end + vm_mod.deck_size - 1) >> @intCast(vm_mod.deck_bits);
    const deck_count = last_deck - first_deck;
    const deck_ptr: [*]u8 = @ptrFromInt(decks_offset + first_deck);
    @memset(deck_ptr[0..deck_count], 0);
}

// Clear write-barrier cards/decks for an arbitrary address range.
// ensuring partial boundary decks belonging to adjacent generations aren't cleared.
// Deck bytes are accessed via offset-based indexing to match the JIT write barrier.
pub fn clearWriteBarrierRange(gc: *GC, start: Cell, end: Cell) void {
    if (start >= end) return;

    if (gc.vm.cards_array) |cards| {
        const base = gc.heap.segment.start;
        const max_end = base + @as(Cell, @intCast(cards.len)) * vm_mod.card_size;
        const clamped_start = @max(start, base);
        const clamped_end = @min(end, max_end);
        if (clamped_start < clamped_end) {
            const first_card = (clamped_start - base) >> @intCast(vm_mod.card_bits);
            const last_card = (clamped_end - base) >> @intCast(vm_mod.card_bits);
            if (first_card < last_card and first_card < cards.len) {
                const end_card = @min(last_card, cards.len);
                @memset(cards[first_card..end_card], 0);
            }
        }
    }

    // Clear decks using offset-based access (matching JIT write barrier).
    // Only clear decks fully contained within the range.
    const decks_offset = gc.vm.vm_asm.decks_offset;
    if (decks_offset != 0) {
        const clamped_start = @max(start, gc.heap.segment.start);
        const clamped_end = @min(end, gc.heap.segment.end);
        if (clamped_start < clamped_end) {
            // Align start UP to deck boundary, end DOWN (floor division).
            const first_deck_abs = (clamped_start + vm_mod.deck_size - 1) >> @intCast(vm_mod.deck_bits);
            const last_deck_abs = clamped_end >> @intCast(vm_mod.deck_bits);
            if (first_deck_abs < last_deck_abs) {
                const deck_count = last_deck_abs - first_deck_abs;
                const deck_ptr: [*]u8 = @ptrFromInt(decks_offset +% first_deck_abs);
                @memset(deck_ptr[0..deck_count], 0);
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const fixture = @import("gc_test_fixture.zig");
const testing = std.testing;

test "sweep rebuilds the free list from mark bits and keeps live objects intact" {
    var f: fixture.Fixture = undefined;
    try f.init();
    defer f.deinit();

    const tenured = f.tenured();
    const a = f.tenuredArray(2, layouts.tagFixnum(1));
    const b = f.tenuredArray(6, layouts.tagFixnum(2)); // garbage, 64 bytes
    const c = f.tenuredArray(130, layouts.tagFixnum(3)); // live, spans several cards
    const d = f.tenuredArray(4, layouts.tagFixnum(4)); // garbage, 48 bytes
    const e = f.tenuredArray(2, layouts.tagFixnum(5));

    fixture.arrayAt(a).data()[0] = c;
    fixture.arrayAt(c).data()[129] = e;
    f.vm.push(a);

    f.fullMark();
    sweepPhase(&f.gc);

    const live = fixture.arraySize(2) * 2 + fixture.arraySize(130);
    try testing.expectEqual(tenured.size - live, tenured.freeBytes());
    try testing.expectEqual(live, tenured.usedBytes());
    // Holes at b and d plus the trailing block.
    try testing.expectEqual(@as(Cell, 3), tenured.free_list.freeBlockCount());
    try testing.expectEqual(tenured.size - live - fixture.arraySize(6) - fixture.arraySize(4), tenured.free_list.largestFreeBlock());

    // Garbage became free blocks of the right size.
    const b_free: *const free_list_mod.FreeBlock = @ptrFromInt(layouts.UNTAG(b));
    const d_free: *const free_list_mod.FreeBlock = @ptrFromInt(layouts.UNTAG(d));
    try testing.expect(b_free.isFree());
    try testing.expect(d_free.isFree());
    try testing.expectEqual(fixture.arraySize(6), b_free.size());
    try testing.expectEqual(fixture.arraySize(4), d_free.size());

    // Live objects were not touched.
    try testing.expect(!fixture.objectAt(a).isFree());
    try testing.expect(!fixture.objectAt(c).isFree());
    try testing.expect(!fixture.objectAt(e).isFree());
    try testing.expectEqual(c, fixture.arrayAt(a).data()[0]);
    try testing.expectEqual(e, fixture.arrayAt(c).data()[129]);
    try testing.expectEqual(layouts.tagFixnum(3), fixture.arrayAt(c).data()[64]);
    try testing.expectEqual(@as(Cell, 130), fixture.arrayAt(c).getCapacity());

    // The holes are reusable by subsequent tenured allocation.
    const reuse_b = f.heap.allocateTenured(fixture.arraySize(6)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(layouts.UNTAG(b), reuse_b);
    const reuse_d = f.heap.allocateTenured(fixture.arraySize(4)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(layouts.UNTAG(d), reuse_d);
    try testing.expectEqual(@as(Cell, 1), tenured.free_list.freeBlockCount());
}

test "sweep coalesces adjacent garbage into one free block" {
    var f: fixture.Fixture = undefined;
    try f.init();
    defer f.deinit();

    const tenured = f.tenured();
    const a = f.tenuredArray(1, layouts.false_object);
    const g1 = f.tenuredArray(3, layouts.false_object);
    _ = f.tenuredArray(9, layouts.false_object);
    _ = f.tenuredArray(1, layouts.false_object);
    const e = f.tenuredArray(1, layouts.false_object);
    fixture.arrayAt(a).data()[0] = e;
    f.vm.push(a);

    f.fullMark();
    sweepPhase(&f.gc);

    const hole = fixture.arraySize(3) + fixture.arraySize(9) + fixture.arraySize(1);
    try testing.expectEqual(@as(Cell, 2), tenured.free_list.freeBlockCount());
    const hole_block: *const free_list_mod.FreeBlock = @ptrFromInt(layouts.UNTAG(g1));
    try testing.expect(hole_block.isFree());
    try testing.expectEqual(hole, hole_block.size());
    try testing.expectEqual(layouts.UNTAG(g1) + hole, layouts.UNTAG(e));
}

test "sweep with no live objects frees the whole tenured space" {
    var f: fixture.Fixture = undefined;
    try f.init();
    defer f.deinit();

    const tenured = f.tenured();
    _ = f.tenuredArray(1, layouts.false_object);
    _ = f.tenuredArray(40, layouts.false_object);
    _ = f.tenuredByteArray("garbage");

    f.fullMark();
    sweepPhase(&f.gc);

    try testing.expectEqual(tenured.size, tenured.freeBytes());
    try testing.expectEqual(@as(Cell, 1), tenured.free_list.freeBlockCount());
    try testing.expectEqual(tenured.size, tenured.free_list.largestFreeBlock());
    const reused = f.heap.allocateTenured(16) orelse return error.TestUnexpectedResult;
    try testing.expect(tenured.contains(reused));
}

test "sweep keeps the object start map usable for a live multi-card object" {
    var f: fixture.Fixture = undefined;
    try f.init();
    defer f.deinit();

    const tenured = f.tenured();
    _ = f.tenuredArray(1, layouts.false_object); // garbage at the start
    const big = f.tenuredArray(200, layouts.false_object); // 1616 bytes, > 6 cards
    const after = f.tenuredArray(1, layouts.false_object);
    fixture.arrayAt(big).data()[0] = after;
    f.vm.push(big);

    f.fullMark();
    sweepPhase(&f.gc);

    // Walking back from a card in the middle of `big` must find `big`.
    const osm = &tenured.object_start;
    const mid_card = (layouts.UNTAG(big) - tenured.start) / vm_mod.card_size + 3;
    const found = osm.findObjectContainingCard(mid_card) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(layouts.UNTAG(big), found);
}

test "sweep clears the tenured card table" {
    var f: fixture.Fixture = undefined;
    try f.init();
    defer f.deinit();

    const a = f.tenuredArray(2, layouts.false_object);
    const slot = &fixture.arrayAt(a).data()[0];
    f.vm.push(a);
    f.vm.writeBarrier(slot);
    try testing.expect(f.cardByte(slot) != 0);

    f.fullMark();
    sweepPhase(&f.gc);

    try testing.expectEqual(@as(u8, 0), f.cardByte(slot));
}
