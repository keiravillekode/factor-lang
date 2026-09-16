// callstack_lookup.zig - Shared fast lookup helpers for callstack walking
//
// Centralizes code-block owner and callsite lookup caches used by GC phases.

const std = @import("std");

const code_blocks = @import("code_blocks.zig");
const code_heap_mod = @import("code_heap.zig");
const layouts = @import("layouts.zig");

const Cell = layouts.Cell;

pub const Lookup = struct {
    blocks: []const Cell,
    cached_owner: ?*const code_blocks.CodeBlock = null,
    cached_start: Cell = 0,
    cached_end: Cell = 0,
    cached_gc_info: ?*const code_blocks.GcInfo = null,
    cached_callsite_return_offset: u32 = 0,
    cached_callsite_index: ?u32 = null,

    const Self = @This();

    pub fn init(code_heap: *code_heap_mod.CodeHeap) ?Self {
        code_heap.flushPending();
        const blocks = code_heap.all_blocks_sorted.items;
        if (blocks.len == 0) return null;
        return .{ .blocks = blocks };
    }

    // Returns owner only if address is inside the block extent.
    pub fn ownerForAddress(self: *Self, address: Cell) ?*const code_blocks.CodeBlock {
        if (self.cached_owner) |owner| {
            if (address >= self.cached_start and address < self.cached_end) {
                return owner;
            }
        }

        const ub = std.sort.upperBound(Cell, self.blocks, address, layouts.orderCell);
        if (ub == 0) return null;

        const block_start = self.blocks[ub - 1];
        const block: *const code_blocks.CodeBlock = @ptrFromInt(block_start);
        const block_end = block_start + block.size();
        if (address >= block_end) return null;

        self.cached_owner = block;
        self.cached_start = block_start;
        self.cached_end = block_end;
        return block;
    }

    // Returns previous block by address order; caller validates extent if needed.
    pub fn ownerForAddressUnsafe(self: *Self, address: Cell) ?*const code_blocks.CodeBlock {
        if (self.cached_owner) |owner| {
            if (address >= self.cached_start and address < self.cached_end) {
                return owner;
            }
        }

        const ub = std.sort.upperBound(Cell, self.blocks, address, layouts.orderCell);
        if (ub == 0) return null;

        const block_start = self.blocks[ub - 1];
        const block: *const code_blocks.CodeBlock = @ptrFromInt(block_start);
        self.cached_owner = block;
        self.cached_start = block_start;
        self.cached_end = block_start + block.size();
        return block;
    }

    // Cached gc_info.returnAddressIndex lookup for repeated PCs in same callsite.
    pub fn callsiteIndex(self: *Self, gc_info: *const code_blocks.GcInfo, return_address_offset: u32) ?u32 {
        if (self.cached_gc_info == gc_info and
            self.cached_callsite_return_offset == return_address_offset)
        {
            return self.cached_callsite_index;
        }

        const found = gc_info.returnAddressIndex(return_address_offset);
        self.cached_gc_info = gc_info;
        self.cached_callsite_return_offset = return_address_offset;
        self.cached_callsite_index = found;
        return found;
    }

    pub fn frameSizeFromAddress(owner: *const code_blocks.CodeBlock, addr: Cell) Cell {
        const entry_point = owner.entryPoint();
        const delta = if (addr > entry_point) addr - entry_point else 0;
        const natural_frame_size = owner.stackFrameSize();
        if (natural_frame_size > 0 and delta > 0) {
            return natural_frame_size;
        }
        return code_blocks.CodeBlock.LEAF_FRAME_SIZE;
    }
};

// --- Tests ---

const testing = std.testing;
const segments = @import("segments.zig");
const free_list_mod = @import("free_list.zig");
const write_barrier = @import("write_barrier.zig");

const LookupEnv = struct {
    seg: segments.Segment,
    fl: *free_list_mod.FreeListAllocator,
    heap: *code_heap_mod.CodeHeap,

    fn init(allocator: std.mem.Allocator) !LookupEnv {
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

    fn deinit(self: *LookupEnv, allocator: std.mem.Allocator) void {
        self.heap.deinit();
        allocator.destroy(self.heap);
        self.fl.deinit();
        allocator.destroy(self.fl);
        self.seg.deinit();
    }

    fn block(self: *LookupEnv, size: Cell, frame_size: Cell) *code_blocks.CodeBlock {
        const b = self.heap.allocate(size).?;
        b.initialize(.optimized, size, frame_size);
        return b;
    }
};

// Hand-built GcInfo: 4 GC roots, 2 derived roots, 2 callsites with return
// address offsets 0x10 and 0x20. Callsite 1 has derived root 0 based on
// spill slot 2 and GC roots at slots 0 and 2; callsite 0 has nothing.
// The layout, from the end of the code block backwards, is: GcInfo,
// return_addresses[2], base_pointer_map[2 * 2], bitmap bytes.
const GcInfoWords = struct {
    words: [10]u32 align(8),

    fn init() GcInfoWords {
        var g: GcInfoWords = .{ .words = .{0} ** 10 };
        // The single bitmap byte is the byte just before the base pointer
        // map, i.e. the high byte of words[0].
        g.words[0] = @as(u32, 0x50) << 24;
        g.words[1] = 0xFFFFFFFF;
        g.words[2] = 0xFFFFFFFF;
        g.words[3] = 2;
        g.words[4] = 0xFFFFFFFF;
        g.words[5] = 0x10;
        g.words[6] = 0x20;
        g.words[7] = 4; // gc_root_count
        g.words[8] = 2; // derived_root_count
        g.words[9] = 2; // return_address_count
        return g;
    }

    fn info(self: *const GcInfoWords) *const code_blocks.GcInfo {
        return @ptrCast(&self.words[7]);
    }
};

test "Lookup.ownerForAddress finds the block containing an address" {
    const allocator = testing.allocator;
    var env = try LookupEnv.init(allocator);
    defer env.deinit(allocator);

    // No blocks: no lookup.
    try testing.expect(Lookup.init(env.heap) == null);

    const a = env.block(64, 32);
    const b = env.block(96, 0);
    const a_start = @intFromPtr(a);
    const b_start = @intFromPtr(b);
    try testing.expect(b_start >= a_start + 64 or a_start >= b_start + 96);

    // init flushes pending inserts into the sorted list.
    var lookup = Lookup.init(env.heap).?;
    try testing.expectEqual(@as(usize, 2), lookup.blocks.len);
    try testing.expect(lookup.blocks[0] < lookup.blocks[1]);

    try testing.expectEqual(a, lookup.ownerForAddress(a_start).?);
    try testing.expectEqual(a, lookup.ownerForAddress(a.entryPoint()).?);
    try testing.expectEqual(a, lookup.ownerForAddress(a_start + 63).?);
    try testing.expectEqual(b, lookup.ownerForAddress(b_start + 95).?);
    try testing.expectEqual(b, lookup.ownerForAddress(b.entryPoint() + 4).?);

    // The cache is keyed on the block extent and answers repeated lookups.
    try testing.expectEqual(a, lookup.ownerForAddress(a_start + 8).?);
    try testing.expectEqual(a, lookup.cached_owner.?);
    try testing.expectEqual(a_start, lookup.cached_start);
    try testing.expectEqual(a_start + 64, lookup.cached_end);
    try testing.expectEqual(a, lookup.ownerForAddress(a_start + 16).?);

    // Before the first block, or past the end of the last one: nothing.
    const first = @min(a_start, b_start);
    const last = @max(a_start, b_start);
    const last_size: Cell = if (last == a_start) 64 else 96;
    try testing.expect(lookup.ownerForAddress(first - 8) == null);
    try testing.expect(lookup.ownerForAddress(last + last_size) == null);
    try testing.expect(lookup.ownerForAddress(env.seg.end + 0x1000) == null);

    // The unsafe variant hands back the preceding block regardless of extent.
    const last_block: *code_blocks.CodeBlock = @ptrFromInt(last);
    try testing.expectEqual(last_block, lookup.ownerForAddressUnsafe(last + last_size + 128).?);
    try testing.expect(lookup.ownerForAddressUnsafe(first - 8) == null);
}

test "Lookup.callsiteIndex caches return address lookups per GcInfo" {
    const allocator = testing.allocator;
    var env = try LookupEnv.init(allocator);
    defer env.deinit(allocator);
    _ = env.block(64, 32);
    var lookup = Lookup.init(env.heap).?;

    const g = GcInfoWords.init();
    const info = g.info();
    try testing.expectEqual(@as(?u32, 0), lookup.callsiteIndex(info, 0x10));
    try testing.expectEqual(@as(?u32, 1), lookup.callsiteIndex(info, 0x20));
    try testing.expectEqual(info, lookup.cached_gc_info.?);
    try testing.expectEqual(@as(u32, 0x20), lookup.cached_callsite_return_offset);
    // Cached answer for the same query.
    try testing.expectEqual(@as(?u32, 1), lookup.callsiteIndex(info, 0x20));
    // Unknown return address.
    try testing.expectEqual(@as(?u32, null), lookup.callsiteIndex(info, 0x30));
    try testing.expectEqual(@as(?u32, null), lookup.callsiteIndex(info, 0x30));
    try testing.expectEqual(@as(?u32, 0), lookup.callsiteIndex(info, 0x10));
}

test "Lookup.frameSizeFromAddress uses the natural frame size past the entry point" {
    const allocator = testing.allocator;
    var env = try LookupEnv.init(allocator);
    defer env.deinit(allocator);
    const with_frame = env.block(64, 32);
    const leaf = env.block(64, 0);

    try testing.expectEqual(code_blocks.CodeBlock.LEAF_FRAME_SIZE, Lookup.frameSizeFromAddress(with_frame, with_frame.entryPoint()));
    try testing.expectEqual(@as(Cell, 32), Lookup.frameSizeFromAddress(with_frame, with_frame.entryPoint() + 4));
    try testing.expectEqual(code_blocks.CodeBlock.LEAF_FRAME_SIZE, Lookup.frameSizeFromAddress(leaf, leaf.entryPoint()));
    try testing.expectEqual(code_blocks.CodeBlock.LEAF_FRAME_SIZE, Lookup.frameSizeFromAddress(leaf, leaf.entryPoint() + 8));
    // An address before the entry point (inside the header) counts as the entry.
    try testing.expectEqual(code_blocks.CodeBlock.LEAF_FRAME_SIZE, Lookup.frameSizeFromAddress(with_frame, @intFromPtr(with_frame)));
}
