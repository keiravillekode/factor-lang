// code_heap.zig - Code heap management
// Manages the JIT-compiled code heap: allocation, block tracking,
// remembered sets for GC, scan flags, and mark bits.

const std = @import("std");
const builtin = @import("builtin");

const code_blocks_mod = @import("code_blocks.zig");
const free_list = @import("free_list.zig");
const layouts = @import("layouts.zig");
const mark_bits = @import("mark_bits.zig");
const segments = @import("segments.zig");
const write_barrier = @import("write_barrier.zig");

const Cell = layouts.Cell;
const CodeBlock = code_blocks_mod.CodeBlock;

pub const CodeHeap = struct {
    seg: ?*segments.Segment,
    free_list: ?*free_list.FreeListAllocator = null, // typed allocator for JIT
    safepoint_page: Cell,
    // Code heap address range (for callstack walking)
    code_start: Cell = 0,
    code_size: Cell = 0,
    // Source of truth for live code block addresses (kept sorted).
    // New inserts go to pending_blocks (O(1) append) and are merged
    // into the sorted list lazily via flushPending().
    all_blocks_sorted: std.ArrayList(Cell) = .empty,
    pending_blocks: std.ArrayListUnmanaged(Cell) = .empty,
    // Memory allocator used for code heap metadata (mark bits, hash maps, etc.)
    allocator: ?std.mem.Allocator = null,
    // Remembered sets for GC - track code blocks that may reference young objects
    remembered_sets: write_barrier.CodeHeapRememberedSets,
    // Scan flags for code heap GC (skip blocks without literals/code pointers)
    scan_literals: ?std.DynamicBitSet = null,
    scan_code_ptrs: ?std.DynamicBitSet = null,
    // Uninitialized blocks: code blocks allocated but not yet relocated.
    // Maps block address -> literals Cell for deferred initialization.
    uninitialized_blocks: std.AutoArrayHashMapUnmanaged(Cell, Cell) = .{},
    // Scratch map reused during compaction to avoid repeated allocations.
    uninitialized_blocks_scratch: std.AutoArrayHashMapUnmanaged(Cell, Cell) = .{},
    marks: ?*mark_bits.MarkBits = null,

    const Self = @This();

    pub fn allocate(self: *Self, size: Cell) ?*CodeBlock {
        const alloc = self.free_list orelse return null;
        const aligned_size = layouts.alignCell(size, layouts.data_alignment);
        if (alloc.allocate(aligned_size)) |addr| {
            const block: *CodeBlock = @ptrFromInt(addr);
            // Add to all_blocks for codeBlockForAddress to find
            self.addToAllBlocks(addr);
            return block;
        }
        return null;
    }

    fn addToAllBlocks(self: *Self, block_addr: Cell) void {
        const al = self.allocator orelse return;
        self.pending_blocks.append(al, block_addr) catch @panic("OOM");
    }

    // Merge pending inserts into the sorted list. Call before bulk iteration
    // or binary-search-dependent operations.
    pub fn flushPending(self: *Self) void {
        if (self.pending_blocks.items.len == 0) return;
        self.flushPendingSlow();
    }

    fn flushPendingSlow(self: *Self) void {
        const pending = self.pending_blocks.items;
        const al = self.allocator orelse return;

        // Sort pending, then merge into sorted list
        std.mem.sortUnstable(Cell, pending, {}, std.sort.asc(Cell));

        const old_len = self.all_blocks_sorted.items.len;
        const new_total = old_len + pending.len;
        self.all_blocks_sorted.ensureTotalCapacity(al, new_total) catch @panic("OOM");

        // Merge: append pending, then do a single merge pass in-place.
        // Since both halves are sorted, we merge from the end backwards.
        self.all_blocks_sorted.items.len = new_total;
        const items = self.all_blocks_sorted.items;

        var dst = new_total;
        var a = old_len; // end of sorted portion
        var b = pending.len; // end of pending portion

        while (b > 0) {
            if (a > 0 and items[a - 1] >= pending[b - 1]) {
                dst -= 1;
                a -= 1;
                items[dst] = items[a];
            } else {
                dst -= 1;
                b -= 1;
                items[dst] = pending[b];
            }
        }
        // Remaining items[0..a] are already in place at items[0..dst] since dst == a.

        // Deduplicate (pending may contain addresses already in sorted list)
        if (items.len > 1) {
            var write: usize = 1;
            for (items[1..]) |v| {
                if (v != items[write - 1]) {
                    items[write] = v;
                    write += 1;
                }
            }
            self.all_blocks_sorted.items.len = write;
        }

        self.pending_blocks.clearRetainingCapacity();
    }

    pub fn occupiedSpace(self: *const Self) Cell {
        if (self.free_list) |alloc| {
            return alloc.size - alloc.free_space;
        }
        return self.code_size; // If no allocator, assume all space is occupied
    }

    /// Returns the byte extent from code_start to the end of the last occupied
    /// block. Unlike occupiedSpace() (which sums non-free bytes), this accounts
    /// for free blocks interleaved among occupied ones. Needed by save-image
    /// because the Zig VM does not compact the code heap.
    pub fn codeHeapExtent(self: *const Self) Cell {
        const end = self.code_start + self.code_size;
        var current = self.code_start;
        var last_occupied_end: Cell = self.code_start;

        while (current < end) {
            const block: *const CodeBlock = @ptrFromInt(current);
            const block_size = block.size();
            if (block_size == 0) break;
            if (!block.isFree()) {
                last_occupied_end = current + block_size;
            }
            current += block_size;
        }
        return last_occupied_end - self.code_start;
    }

    pub fn writeBarrier(self: *Self, compiled: *CodeBlock) !void {
        try self.remembered_sets.ensureInitialized(self.code_start, self.code_size);
        try self.remembered_sets.writeBarrier(compiled);
    }

    pub fn ensureScanFlags(self: *Self, al: std.mem.Allocator) !void {
        if (self.scan_literals != null and self.scan_code_ptrs != null) return;
        const bit_count: usize = @intCast(self.code_size / layouts.data_alignment);
        self.scan_literals = try std.DynamicBitSet.initEmpty(al, bit_count);
        self.scan_code_ptrs = try std.DynamicBitSet.initEmpty(al, bit_count);
    }

    fn blockIndex(self: *const Self, block: *CodeBlock) usize {
        return @intCast((@intFromPtr(block) - self.code_start) / layouts.data_alignment);
    }

    fn blockIndexFromAddress(self: *const Self, block_addr: Cell) usize {
        return @intCast((block_addr - self.code_start) / layouts.data_alignment);
    }

    pub fn updateScanFlags(self: *Self, al: std.mem.Allocator, block: *CodeBlock) void {
        // Graceful degradation: without scan flags, all blocks are scanned (slower but correct)
        self.ensureScanFlags(al) catch return;
        const flags = code_blocks_mod.scanRelocationFlags(block);
        const idx = self.blockIndex(block);
        if (self.scan_literals) |*set| {
            if (flags.has_literals) set.set(idx) else set.unset(idx);
        }
        if (self.scan_code_ptrs) |*set| {
            if (flags.has_code_ptrs) set.set(idx) else set.unset(idx);
        }
    }

    pub fn putUninitializedBlock(self: *Self, al: std.mem.Allocator, block_addr: Cell, literals_cell: Cell) !void {
        try self.uninitialized_blocks.put(al, block_addr, literals_cell);
    }

    pub fn removeUninitializedBlock(self: *Self, block_addr: Cell) bool {
        return self.uninitialized_blocks.swapRemove(block_addr);
    }

    pub fn clearUninitializedBlocks(self: *Self) void {
        self.uninitialized_blocks.clearRetainingCapacity();
    }

    pub fn isBlockUninitialized(self: *const Self, block: *const CodeBlock) bool {
        return self.isUninitializedAddress(@intFromPtr(block));
    }

    pub fn isUninitializedAddress(self: *const Self, block_addr: Cell) bool {
        return self.uninitialized_blocks.contains(block_addr);
    }

    pub fn removeScanFlags(self: *Self, block: *CodeBlock) void {
        if (self.scan_literals == null or self.scan_code_ptrs == null) return;
        const idx = self.blockIndex(block);
        if (self.scan_literals) |*set| set.unset(idx);
        if (self.scan_code_ptrs) |*set| set.unset(idx);
    }

    pub fn removeScanFlagsByAddress(self: *Self, block_addr: Cell) void {
        if (self.scan_literals == null or self.scan_code_ptrs == null) return;
        const idx = self.blockIndexFromAddress(block_addr);
        if (self.scan_literals) |*set| set.unset(idx);
        if (self.scan_code_ptrs) |*set| set.unset(idx);
    }

    pub fn clearScanFlags(self: *Self) void {
        if (self.scan_literals) |*set| set.unmanaged.unsetAll();
        if (self.scan_code_ptrs) |*set| set.unmanaged.unsetAll();
    }

    pub fn blockHasLiterals(self: *const Self, block: *CodeBlock) bool {
        if (self.scan_literals) |set| return set.isSet(self.blockIndex(block));
        return true;
    }

    pub fn blockHasCodePointers(self: *const Self, block: *CodeBlock) bool {
        if (self.scan_code_ptrs) |set| return set.isSet(self.blockIndex(block));
        return true;
    }

    pub fn clearRememberedSets(self: *Self) void {
        self.remembered_sets.clear();
    }

    pub fn free(self: *Self, block: *CodeBlock) void {
        self.remembered_sets.removeCodeBlock(block);
        self.removeScanFlags(block);
        const block_addr = @intFromPtr(block);
        _ = self.removeUninitializedBlock(block_addr);

        self.removeFromAllBlocks(@intFromPtr(block));

        const size = block.size();
        block.markFree(size);
        if (self.free_list) |alloc| {
            alloc.free(@intFromPtr(block), size);
        }
    }

    fn removeFromAllBlocks(self: *Self, block_addr: Cell) void {
        // Check pending first (swap-remove is O(1))
        for (self.pending_blocks.items, 0..) |addr, i| {
            if (addr == block_addr) {
                _ = self.pending_blocks.swapRemove(i);
                return;
            }
        }
        // Fall back to sorted list: O(log n) search + O(n) shift
        const items = self.all_blocks_sorted.items;
        const pos = std.sort.lowerBound(Cell, items, block_addr, layouts.orderCell);
        if (pos < items.len and items[pos] == block_addr) {
            _ = self.all_blocks_sorted.orderedRemove(pos);
        }
    }

    // Batch remove addresses from all_blocks_sorted.
    pub fn batchRemoveFromAllBlocks(self: *Self, removes: []const Cell) void {
        if (removes.len == 0) return;

        if (!isNonDecreasing(removes)) {
            for (removes) |addr| {
                self.removeFromAllBlocks(addr);
            }
            return;
        }

        const items = self.all_blocks_sorted.items;
        var write_idx: usize = 0;
        var remove_idx: usize = 0;

        for (items) |addr| {
            while (remove_idx < removes.len and removes[remove_idx] < addr) : (remove_idx += 1) {}

            if (remove_idx < removes.len and removes[remove_idx] == addr) {
                // Skip duplicate remove entries for the same address.
                const removed_addr = addr;
                while (remove_idx < removes.len and removes[remove_idx] == removed_addr) : (remove_idx += 1) {}
                continue;
            }

            items[write_idx] = addr;
            write_idx += 1;
        }

        self.all_blocks_sorted.items.len = write_idx;
    }

    // Free a code block without removing from all_blocks.
    // Used for batch freeing where all_blocks is updated separately.
    pub fn freeBlockOnly(self: *Self, block: *CodeBlock) void {
        self.remembered_sets.removeCodeBlock(block);
        self.removeScanFlags(block);
        const block_addr = @intFromPtr(block);
        _ = self.removeUninitializedBlock(block_addr);

        const size = block.size();
        block.markFree(size);
        if (self.free_list) |alloc| {
            alloc.free(@intFromPtr(block), size);
        }
    }

    pub fn codeBlockForAddress(self: *Self, address: Cell) ?*CodeBlock {
        // Check sorted list first (binary search)
        const blocks = self.all_blocks_sorted.items;
        if (blocks.len > 0) {
            const ub = std.sort.upperBound(Cell, blocks, address, layouts.orderCell);
            if (ub > 0) {
                const block: *CodeBlock = @ptrFromInt(blocks[ub - 1]);
                const block_end = blocks[ub - 1] + block.size();
                if (address < block_end) return block;
            }
        }

        // Check pending blocks (linear scan — typically small)
        for (self.pending_blocks.items) |block_addr| {
            if (address >= block_addr) {
                const block: *CodeBlock = @ptrFromInt(block_addr);
                const block_end = block_addr + block.size();
                if (address < block_end) return block;
            }
        }

        return null;
    }

    // Get the predecessor frame (caller's frame) given the current frame top
    pub fn framePredecessor(self: *Self, frame_top: Cell) Cell {
        if (builtin.cpu.arch == .aarch64) {
            // ARM64: frame_top[0] contains the saved frame pointer (x29)
            // which points directly to the previous frame
            return @as(*const Cell, @ptrFromInt(frame_top)).*;
        } else {
            // x86-64: FRAME_RETURN_ADDRESS = 0, so return address is at frame_top
            // We compute the next frame by adding the frame size
            const FRAME_RETURN_ADDRESS: Cell = 0;
            const addr = @as(*const Cell, @ptrFromInt(frame_top + FRAME_RETURN_ADDRESS)).*;
            const block = self.codeBlockForAddress(addr) orelse {
                // Can't find code block - return minimum frame size
                return frame_top + CodeBlock.LEAF_FRAME_SIZE;
            };
            const frame_size = block.stackFrameSizeForAddress(addr);
            return frame_top + frame_size;
        }
    }

    // Verify that all live code blocks in the heap are present in all_blocks_sorted.
    // Catches missed inserts/removes or stale entries.
    pub fn verifyAllBlocksSet(self: *const Self) void {
        if (comptime builtin.mode != .Debug) return;
        if (self.code_start == 0 or self.code_size == 0) return;

        const code_end = self.code_start + self.code_size;
        var idx: usize = 0;
        var current = self.code_start;

        while (current < code_end) {
            const block: *const CodeBlock = @ptrFromInt(current);
            const block_size = codeBlockSize(current);
            if (block_size == 0) break;

            if (!block.isFree()) {
                std.debug.assert(idx < self.all_blocks_sorted.items.len);
                std.debug.assert(self.all_blocks_sorted.items[idx] == current);
                idx += 1;
            }
            current += block_size;
        }

        std.debug.assert(idx == self.all_blocks_sorted.items.len);
        if (self.all_blocks_sorted.items.len > 1) {
            for (1..self.all_blocks_sorted.items.len) |i| {
                std.debug.assert(self.all_blocks_sorted.items[i - 1] < self.all_blocks_sorted.items[i]);
            }
        }
    }

    // Initialize all_blocks_sorted by scanning the code heap.
    // This must be called after image loading/fixup
    pub fn initializeAllBlocksSet(self: *Self) !void {
        if (self.code_start == 0 or self.code_size == 0) return;

        const alloc = self.allocator orelse return;

        // First pass: count non-free blocks
        var count: usize = 0;
        var current = self.code_start;
        const code_end = self.code_start + self.code_size;

        while (current < code_end) {
            const block_size = codeBlockSize(current);
            if (block_size == 0) break;
            const block: *const CodeBlock = @ptrFromInt(current);
            if (!block.isFree()) {
                count += 1;
            }
            current += block_size;
        }

        // Rebuild sorted array (pending is stale after full scan).
        self.pending_blocks.clearRetainingCapacity();
        self.all_blocks_sorted.clearRetainingCapacity();
        try self.all_blocks_sorted.ensureTotalCapacity(alloc, count);
        // Second pass: populate. Iteration order is ascending address, so
        // all_blocks_sorted is naturally sorted without a separate sort call.
        current = self.code_start;
        while (current < code_end) {
            const block_size = codeBlockSize(current);
            if (block_size == 0) break;
            const block: *const CodeBlock = @ptrFromInt(current);
            if (!block.isFree()) {
                self.all_blocks_sorted.appendAssumeCapacity(current);
            }
            current += block_size;
        }

        self.verifyAllBlocksSet();
    }

    pub fn rebuildScanFlags(self: *Self, al: std.mem.Allocator) void {
        self.flushPending();
        self.ensureScanFlags(al) catch return;
        self.clearScanFlags();
        for (self.all_blocks_sorted.items) |block_addr| {
            const block: *CodeBlock = @ptrFromInt(block_addr);
            if (!block.isFree()) {
                self.updateScanFlags(al, block);
            }
        }
    }

    pub fn ensureMarks(self: *Self, al: std.mem.Allocator) !void {
        if (self.marks != null) return;
        if (self.code_start == 0 or self.code_size == 0) return;
        const marks = try al.create(mark_bits.MarkBits);
        errdefer al.destroy(marks);
        marks.* = try mark_bits.MarkBits.init(al, self.code_start, self.code_size);
        self.marks = marks;
        self.allocator = al;
    }

    pub fn clearMarks(self: *Self) void {
        if (self.marks) |marks| {
            marks.clearMarks();
        }
    }

    pub fn deinit(self: *Self) void {
        const alloc = self.allocator orelse return;
        self.pending_blocks.deinit(alloc);
        self.all_blocks_sorted.deinit(alloc);
        self.uninitialized_blocks.deinit(alloc);
        self.uninitialized_blocks_scratch.deinit(alloc);
        // Deinit remembered sets and scan flags
        self.remembered_sets.deinit();
        if (self.scan_literals) |*set| {
            set.deinit();
            self.scan_literals = null;
        }
        if (self.scan_code_ptrs) |*set| {
            set.deinit();
            self.scan_code_ptrs = null;
        }
        if (self.marks) |marks| {
            marks.deinit();
            if (self.allocator) |gc_alloc| {
                gc_alloc.destroy(marks);
            }
            self.marks = null;
        }
    }

    pub fn blockSizeAt(self: *const Self, addr: Cell) Cell {
        _ = self;
        return codeBlockSize(addr);
    }
};

// Compute block size at address, handling both code-block and free-list layouts.
// FreeListAllocator encodes size in the header (header = size | 1).
fn codeBlockSize(addr: Cell) Cell {
    const block: *const CodeBlock = @ptrFromInt(addr);
    if (!block.isFree()) {
        return block.size();
    }
    var size = block.size();
    if (size == 0) {
        // For free blocks, read size from header (FreeBlock encodes size in header)
        const free_block: *const free_list.FreeBlock = @ptrFromInt(addr);
        size = free_block.size();
    }
    return size;
}

fn isNonDecreasing(values: []const Cell) bool {
    if (values.len < 2) return true;
    for (1..values.len) |i| {
        if (values[i] < values[i - 1]) return false;
    }
    return true;
}

// --- Tests ---

const testing = std.testing;
const CodeBlockType = code_blocks_mod.CodeBlockType;
const RelocationEntry = code_blocks_mod.RelocationEntry;

// A code heap over a page-aligned buffer (never executed), with the same
// free-list allocator the image loader installs.
const TestCodeHeap = struct {
    region: []u8,
    alloc: free_list.FreeListAllocator,
    heap: CodeHeap,

    fn init(self: *TestCodeHeap, size: Cell) !void {
        self.region = try std.heap.page_allocator.alloc(u8, size);
        @memset(self.region, 0);
        const start_addr = @intFromPtr(self.region.ptr);
        self.alloc = free_list.FreeListAllocator.init(testing.allocator, start_addr, size);
        self.heap = CodeHeap{
            .seg = null,
            .free_list = &self.alloc,
            .safepoint_page = 0,
            .code_start = start_addr,
            .code_size = size,
            .allocator = testing.allocator,
            .remembered_sets = write_barrier.CodeHeapRememberedSets.init(testing.allocator),
        };
    }

    fn deinit(self: *TestCodeHeap) void {
        self.heap.deinit();
        self.alloc.deinit();
        std.heap.page_allocator.free(self.region);
    }

    fn allocBlock(self: *TestCodeHeap, size: Cell, block_type: CodeBlockType) *CodeBlock {
        const block = self.heap.allocate(size) orelse @panic("code heap allocate failed");
        block.initialize(block_type, layouts.alignCell(size, layouts.data_alignment), 0);
        return block;
    }

    fn start(self: *const TestCodeHeap) Cell {
        return self.heap.code_start;
    }

    fn end(self: *const TestCodeHeap) Cell {
        return self.heap.code_start + self.heap.code_size;
    }
};

// Byte array holding relocation entries, in 16-byte aligned stack memory.
const RelocBytes = struct {
    buf: [8]Cell align(16),

    fn init(entries: []const RelocationEntry) RelocBytes {
        var self: RelocBytes = .{ .buf = .{0} ** 8 };
        const ba: *layouts.ByteArray = @ptrCast(&self.buf);
        ba.header = @as(Cell, @intFromEnum(layouts.TypeTag.byte_array)) << 2;
        ba.capacity = layouts.tagFixnum(@intCast(entries.len * @sizeOf(RelocationEntry)));
        for (entries, 0..) |e, i| {
            std.mem.writeInt(u32, ba.data()[i * 4 ..][0..4], e.value, .little);
        }
        return self;
    }

    fn tagged(self: *const RelocBytes) Cell {
        return @intFromPtr(&self.buf) | @intFromEnum(layouts.TypeTag.byte_array);
    }
};

test "code heap allocate, lookup by address and free" {
    var th: TestCodeHeap = undefined;
    try th.init(64 * 1024);
    defer th.deinit();

    const free_before = th.alloc.freeBytes();
    try testing.expectEqual(@as(Cell, 0), th.heap.occupiedSpace());

    const a = th.allocBlock(64, .optimized);
    const b = th.allocBlock(200, .unoptimized);
    try testing.expect(a != b);
    try testing.expectEqual(@as(Cell, 64), a.size());
    try testing.expectEqual(@as(Cell, 208), b.size());
    try testing.expectEqual(@as(Cell, 64 + 208), th.heap.occupiedSpace());
    try testing.expectEqual(free_before - 64 - 208, th.alloc.freeBytes());

    for ([_]*CodeBlock{ a, b }) |blk| {
        const addr = @intFromPtr(blk);
        try testing.expect(addr >= th.start() and addr + blk.size() <= th.end());
        // Start, entry point and last byte resolve to the block.
        try testing.expectEqual(blk, th.heap.codeBlockForAddress(addr).?);
        try testing.expectEqual(blk, th.heap.codeBlockForAddress(blk.entryPoint()).?);
        try testing.expectEqual(blk, th.heap.codeBlockForAddress(addr + blk.size() - 1).?);
        // One past the end is never this block.
        if (th.heap.codeBlockForAddress(addr + blk.size())) |other| {
            try testing.expect(other != blk);
        }
    }
    try testing.expectEqual(@as(?*CodeBlock, null), th.heap.codeBlockForAddress(th.start() - 1));
    try testing.expectEqual(@as(?*CodeBlock, null), th.heap.codeBlockForAddress(th.end()));
    try testing.expectEqual(@as(?*CodeBlock, null), th.heap.codeBlockForAddress(0));

    // Both blocks are still in the pending list; flushing sorts them.
    try testing.expectEqual(@as(usize, 2), th.heap.pending_blocks.items.len);
    th.heap.flushPending();
    try testing.expectEqual(@as(usize, 0), th.heap.pending_blocks.items.len);
    const sorted = th.heap.all_blocks_sorted.items;
    try testing.expectEqual(@as(usize, 2), sorted.len);
    try testing.expect(sorted[0] < sorted[1]);
    th.heap.verifyAllBlocksSet();

    // Lookup still works from the sorted list.
    try testing.expectEqual(a, th.heap.codeBlockForAddress(a.entryPoint() + 3).?);
    try testing.expectEqual(b, th.heap.codeBlockForAddress(b.entryPoint() + 3).?);

    // Freeing returns the bytes, marks the header and drops the block.
    th.heap.free(a);
    try testing.expect(a.isFree());
    try testing.expectEqual(@as(Cell, 64), a.size());
    try testing.expectEqual(@as(Cell, 208), th.heap.occupiedSpace());
    try testing.expectEqual(free_before - 208, th.alloc.freeBytes());
    try testing.expectEqual(@as(?*CodeBlock, null), th.heap.codeBlockForAddress(@intFromPtr(a)));
    try testing.expectEqual(@as(usize, 1), th.heap.all_blocks_sorted.items.len);
    try testing.expectEqual(@intFromPtr(b), th.heap.all_blocks_sorted.items[0]);
    th.heap.verifyAllBlocksSet();

    // The freed bytes are reused by an allocation of the same size.
    const c = th.allocBlock(64, .pic);
    try testing.expectEqual(@intFromPtr(a), @intFromPtr(c));
    try testing.expect(c.isPic());
    th.heap.flushPending();
    th.heap.verifyAllBlocksSet();
}

test "code heap free from the pending list and flush deduplicates" {
    var th: TestCodeHeap = undefined;
    try th.init(64 * 1024);
    defer th.deinit();

    const a = th.allocBlock(48, .optimized);
    const b = th.allocBlock(48, .optimized);
    const c = th.allocBlock(48, .optimized);
    // Free a block that is still pending: removed from pending, never sorted.
    th.heap.free(b);
    try testing.expectEqual(@as(usize, 2), th.heap.pending_blocks.items.len);
    th.heap.flushPending();
    try testing.expectEqual(@as(usize, 2), th.heap.all_blocks_sorted.items.len);
    th.heap.verifyAllBlocksSet();

    // Flushing a duplicate of an already sorted address keeps one entry.
    th.heap.pending_blocks.append(testing.allocator, @intFromPtr(a)) catch unreachable;
    th.heap.pending_blocks.append(testing.allocator, @intFromPtr(c)) catch unreachable;
    th.heap.flushPending();
    try testing.expectEqual(@as(usize, 2), th.heap.all_blocks_sorted.items.len);
    th.heap.verifyAllBlocksSet();

    // Rebuilding from the heap walk gives the same set.
    try th.heap.initializeAllBlocksSet();
    try testing.expectEqual(@as(usize, 2), th.heap.all_blocks_sorted.items.len);
    const lo = @min(@intFromPtr(a), @intFromPtr(c));
    const hi = @max(@intFromPtr(a), @intFromPtr(c));
    try testing.expectEqual(lo, th.heap.all_blocks_sorted.items[0]);
    try testing.expectEqual(hi, th.heap.all_blocks_sorted.items[1]);
}

test "code heap extent covers the last occupied block" {
    var th: TestCodeHeap = undefined;
    try th.init(64 * 1024);
    defer th.deinit();

    try testing.expectEqual(@as(Cell, 0), th.heap.codeHeapExtent());

    const a = th.allocBlock(64, .optimized);
    const b = th.allocBlock(64, .optimized);
    const a_end = @intFromPtr(a) + a.size();
    const b_end = @intFromPtr(b) + b.size();
    try testing.expectEqual(@max(a_end, b_end) - th.start(), th.heap.codeHeapExtent());

    // Free the higher block: the extent shrinks to the lower one.
    const high = if (a_end > b_end) a else b;
    const low = if (a_end > b_end) b else a;
    th.heap.free(high);
    try testing.expectEqual(@intFromPtr(low) + low.size() - th.start(), th.heap.codeHeapExtent());
    th.heap.free(low);
    try testing.expectEqual(@as(Cell, 0), th.heap.codeHeapExtent());
    try testing.expectEqual(@as(Cell, 0), th.heap.occupiedSpace());
}

test "code heap remembered sets track written blocks" {
    var th: TestCodeHeap = undefined;
    try th.init(64 * 1024);
    defer th.deinit();

    const a = th.allocBlock(64, .optimized);
    const b = th.allocBlock(64, .optimized);
    try testing.expect(!th.heap.remembered_sets.hasAny());

    try th.heap.writeBarrier(a);
    try testing.expect(th.heap.remembered_sets.hasAny());
    try testing.expectEqual(@as(usize, 1), th.heap.remembered_sets.nurseryDirtyBlocks().len);
    try testing.expectEqual(@as(usize, 1), th.heap.remembered_sets.agingDirtyBlocks().len);
    const idx = (@intFromPtr(a) - th.start()) / layouts.data_alignment;
    try testing.expectEqual(idx, th.heap.remembered_sets.nurseryDirtyBlocks()[0]);

    // Writing the same block again does not duplicate it.
    try th.heap.writeBarrier(a);
    try testing.expectEqual(@as(usize, 1), th.heap.remembered_sets.nurseryDirtyBlocks().len);
    try th.heap.writeBarrier(b);
    try testing.expectEqual(@as(usize, 2), th.heap.remembered_sets.nurseryDirtyBlocks().len);

    // Freeing a block removes it from the sets; the dirty list keeps a
    // stale entry that iteration filters by isFree().
    th.heap.free(a);
    try testing.expect(th.heap.remembered_sets.hasAny());
    try testing.expectEqual(@as(usize, 1), th.heap.remembered_sets.nursery_count);
    th.heap.free(b);
    try testing.expect(!th.heap.remembered_sets.hasAny());

    const c = th.allocBlock(64, .optimized);
    try th.heap.writeBarrier(c);
    try testing.expect(th.heap.remembered_sets.hasAny());
    th.heap.clearRememberedSets();
    try testing.expect(!th.heap.remembered_sets.hasAny());
    try testing.expectEqual(@as(usize, 0), th.heap.remembered_sets.nurseryDirtyBlocks().len);
}

test "code heap scan flags follow the relocation table" {
    var th: TestCodeHeap = undefined;
    try th.init(64 * 1024);
    defer th.deinit();

    const a = th.allocBlock(64, .optimized);
    const b = th.allocBlock(64, .optimized);
    const c = th.allocBlock(64, .optimized);

    // Without scan flags every block is (conservatively) scanned.
    try testing.expect(th.heap.blockHasLiterals(a));
    try testing.expect(th.heap.blockHasCodePointers(a));

    var lit_only = RelocBytes.init(&.{RelocationEntry.init(.literal, .absolute_cell, 8)});
    var ep_only = RelocBytes.init(&.{RelocationEntry.init(.entry_point, .relative, 8)});
    var both = RelocBytes.init(&.{
        RelocationEntry.init(.vm, .absolute_cell, 8),
        RelocationEntry.init(.literal, .absolute_cell, 16),
        RelocationEntry.init(.entry_point_pic_tail, .relative, 24),
    });
    a.relocation = lit_only.tagged();
    b.relocation = ep_only.tagged();
    c.relocation = both.tagged();

    th.heap.updateScanFlags(testing.allocator, a);
    th.heap.updateScanFlags(testing.allocator, b);
    th.heap.updateScanFlags(testing.allocator, c);
    try testing.expect(th.heap.blockHasLiterals(a));
    try testing.expect(!th.heap.blockHasCodePointers(a));
    try testing.expect(!th.heap.blockHasLiterals(b));
    try testing.expect(th.heap.blockHasCodePointers(b));
    try testing.expect(th.heap.blockHasLiterals(c));
    try testing.expect(th.heap.blockHasCodePointers(c));

    th.heap.removeScanFlags(c);
    try testing.expect(!th.heap.blockHasLiterals(c));
    try testing.expect(!th.heap.blockHasCodePointers(c));
    th.heap.removeScanFlagsByAddress(@intFromPtr(a));
    try testing.expect(!th.heap.blockHasLiterals(a));

    // A rebuild recomputes every live block from its relocation table.
    th.heap.rebuildScanFlags(testing.allocator);
    try testing.expect(th.heap.blockHasLiterals(a));
    try testing.expect(th.heap.blockHasCodePointers(b));
    try testing.expect(th.heap.blockHasLiterals(c) and th.heap.blockHasCodePointers(c));

    th.heap.clearScanFlags();
    try testing.expect(!th.heap.blockHasLiterals(a) and !th.heap.blockHasCodePointers(b));

    // A block with no relocation table has nothing to scan.
    c.relocation = layouts.false_object;
    th.heap.updateScanFlags(testing.allocator, c);
    try testing.expect(!th.heap.blockHasLiterals(c) and !th.heap.blockHasCodePointers(c));
}

test "code heap uninitialized block bookkeeping" {
    var th: TestCodeHeap = undefined;
    try th.init(64 * 1024);
    defer th.deinit();

    const a = th.allocBlock(64, .optimized);
    const b = th.allocBlock(64, .optimized);
    try testing.expect(!th.heap.isBlockUninitialized(a));

    try th.heap.putUninitializedBlock(testing.allocator, @intFromPtr(a), layouts.tagFixnum(7));
    try th.heap.putUninitializedBlock(testing.allocator, @intFromPtr(b), layouts.tagFixnum(9));
    try testing.expect(th.heap.isBlockUninitialized(a));
    try testing.expect(th.heap.isUninitializedAddress(@intFromPtr(b)));
    try testing.expectEqual(layouts.tagFixnum(7), th.heap.uninitialized_blocks.get(@intFromPtr(a)).?);

    try testing.expect(th.heap.removeUninitializedBlock(@intFromPtr(a)));
    try testing.expect(!th.heap.removeUninitializedBlock(@intFromPtr(a)));
    try testing.expect(!th.heap.isBlockUninitialized(a));
    try testing.expect(th.heap.isBlockUninitialized(b));

    // Freeing a block also forgets it.
    th.heap.free(b);
    try testing.expect(!th.heap.isUninitializedAddress(@intFromPtr(b)));

    try th.heap.putUninitializedBlock(testing.allocator, @intFromPtr(a), layouts.false_object);
    th.heap.clearUninitializedBlocks();
    try testing.expectEqual(@as(usize, 0), th.heap.uninitialized_blocks.count());
}

test "code heap mark bits" {
    var th: TestCodeHeap = undefined;
    try th.init(64 * 1024);
    defer th.deinit();

    try testing.expectEqual(@as(?*mark_bits.MarkBits, null), th.heap.marks);
    try th.heap.ensureMarks(testing.allocator);
    const marks = th.heap.marks.?;
    // Idempotent.
    try th.heap.ensureMarks(testing.allocator);
    try testing.expectEqual(marks, th.heap.marks.?);

    const a = th.allocBlock(64, .optimized);
    const b = th.allocBlock(64, .optimized);
    try testing.expect(!marks.isMarked(@intFromPtr(a)));
    try testing.expect(marks.tryMarkStart(@intFromPtr(a), a.size()));
    try testing.expect(!marks.tryMarkStart(@intFromPtr(a), a.size()));
    try testing.expect(marks.isMarked(@intFromPtr(a)));
    try testing.expect(!marks.isMarked(@intFromPtr(b)));
    try testing.expectEqual(a.size() / layouts.data_alignment, marks.countMarked());

    th.heap.clearMarks();
    try testing.expect(!marks.isMarked(@intFromPtr(a)));
    try testing.expectEqual(@as(Cell, 0), marks.countMarked());
}

test "code heap batch removal and freeBlockOnly" {
    var th: TestCodeHeap = undefined;
    try th.init(64 * 1024);
    defer th.deinit();

    var blocks: [4]*CodeBlock = undefined;
    for (&blocks) |*slot| slot.* = th.allocBlock(64, .optimized);
    th.heap.flushPending();
    try testing.expectEqual(@as(usize, 4), th.heap.all_blocks_sorted.items.len);

    // freeBlockOnly frees the memory but leaves all_blocks to the caller.
    th.heap.freeBlockOnly(blocks[0]);
    th.heap.freeBlockOnly(blocks[2]);
    try testing.expect(blocks[0].isFree() and blocks[2].isFree());
    try testing.expectEqual(@as(usize, 4), th.heap.all_blocks_sorted.items.len);

    var removes = [_]Cell{ @intFromPtr(blocks[0]), @intFromPtr(blocks[2]) };
    std.mem.sort(Cell, &removes, {}, std.sort.asc(Cell));
    th.heap.batchRemoveFromAllBlocks(&removes);
    try testing.expectEqual(@as(usize, 2), th.heap.all_blocks_sorted.items.len);
    th.heap.verifyAllBlocksSet();
    try testing.expectEqual(@as(?*CodeBlock, null), th.heap.codeBlockForAddress(@intFromPtr(blocks[0]) + @sizeOf(CodeBlock)));
    try testing.expectEqual(blocks[1], th.heap.codeBlockForAddress(blocks[1].entryPoint()).?);

    // Unsorted (and duplicated) removal lists take the slow path.
    th.heap.freeBlockOnly(blocks[1]);
    th.heap.freeBlockOnly(blocks[3]);
    const hi = @max(@intFromPtr(blocks[1]), @intFromPtr(blocks[3]));
    const lo = @min(@intFromPtr(blocks[1]), @intFromPtr(blocks[3]));
    th.heap.batchRemoveFromAllBlocks(&.{ hi, lo, hi });
    try testing.expectEqual(@as(usize, 0), th.heap.all_blocks_sorted.items.len);
    th.heap.verifyAllBlocksSet();
    try testing.expectEqual(@as(Cell, 0), th.heap.occupiedSpace());

    // Removing addresses that are not present is harmless.
    th.heap.batchRemoveFromAllBlocks(&.{ lo, hi });
    th.heap.batchRemoveFromAllBlocks(&.{});
}

test "code heap frame predecessor on x86-64" {
    if (builtin.cpu.arch != .x86_64) return error.SkipZigTest;

    var th: TestCodeHeap = undefined;
    try th.init(64 * 1024);
    defer th.deinit();

    const block = th.heap.allocate(96).?;
    block.initialize(.optimized, 96, 48);
    th.heap.flushPending();

    // A frame whose return address is inside the block, past the entry point.
    var frame: [2]Cell align(16) = .{ block.entryPoint() + 8, 0 };
    try testing.expectEqual(@intFromPtr(&frame) + 48, th.heap.framePredecessor(@intFromPtr(&frame)));

    // At the entry point itself the frame is still a leaf frame.
    frame[0] = block.entryPoint();
    try testing.expectEqual(@intFromPtr(&frame) + CodeBlock.LEAF_FRAME_SIZE, th.heap.framePredecessor(@intFromPtr(&frame)));

    // A block without a natural frame size is always a leaf.
    const leaf = th.heap.allocate(64).?;
    leaf.initialize(.unoptimized, 64, 0);
    th.heap.flushPending();
    frame[0] = leaf.entryPoint() + 4;
    try testing.expectEqual(@intFromPtr(&frame) + CodeBlock.LEAF_FRAME_SIZE, th.heap.framePredecessor(@intFromPtr(&frame)));

    // An address outside every block falls back to the minimum frame.
    frame[0] = th.end() + 0x1000;
    try testing.expectEqual(@intFromPtr(&frame) + CodeBlock.LEAF_FRAME_SIZE, th.heap.framePredecessor(@intFromPtr(&frame)));
}
