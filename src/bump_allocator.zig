// bump_allocator.zig - Simple bump allocator for nursery
// offset of 'here' and 'end' is hardcoded in compiler backends

const std = @import("std");
const layouts = @import("layouts.zig");
const Cell = layouts.Cell;
const Object = layouts.Object;

// Bump allocator struct - field layout is critical for assembly compatibility
// The fields here, start, end, size must be in this exact order
pub const BumpAllocator = extern struct {
    const Self = @This();

    // Current allocation pointer - offset hardcoded in compiler backends
    here: Cell,
    start: Cell,
    // End of allocation region - offset hardcoded in compiler backends
    end: Cell,
    size: Cell,

    pub fn init(size: Cell, start_addr: Cell) BumpAllocator {
        const aligned_start = layouts.alignCell(start_addr, layouts.data_alignment);
        return BumpAllocator{
            .here = aligned_start,
            .start = aligned_start,
            .end = start_addr + size,
            .size = start_addr + size - aligned_start,
        };
    }

    pub fn contains(self: *const BumpAllocator, obj: *Object) bool {
        const addr = @intFromPtr(obj);
        return addr >= self.start and addr < self.end;
    }

    pub fn flush(self: *BumpAllocator) void {
        self.here = self.start;
        // In debug mode, fill with pattern to catch stale references
        if (std.debug.runtime_safety) {
            const ptr: [*]u8 = @ptrFromInt(self.start);
            @memset(ptr[0..self.size], 0xBA);
        }
    }

    pub fn canAllot(self: *const BumpAllocator, size: Cell) bool {
        return self.here + layouts.alignCell(size, layouts.data_alignment) <= self.end;
    }

    // here is always aligned after init/reset, so only the size needs alignment.
    // Caller (ensureNurserySpace) already
    // checked bounds, so no redundant check needed.
    pub fn allocate(self: *BumpAllocator, size: Cell) Cell {
        const h = self.here;
        self.here = h + layouts.alignCell(size, layouts.data_alignment);
        return h;
    }

    pub fn reset(self: *BumpAllocator) void {
        self.here = self.start;
    }

    pub fn usedBytes(self: *const BumpAllocator) Cell {
        return self.here - self.start;
    }

    pub fn freeBytes(self: *const BumpAllocator) Cell {
        return self.end - self.here;
    }
};

// Compile-time verification of struct layout
comptime {
    // Verify field order for assembly compatibility
    std.debug.assert(@offsetOf(BumpAllocator, "here") == 0 * @sizeOf(Cell));
    std.debug.assert(@offsetOf(BumpAllocator, "start") == 1 * @sizeOf(Cell));
    std.debug.assert(@offsetOf(BumpAllocator, "end") == 2 * @sizeOf(Cell));
    std.debug.assert(@offsetOf(BumpAllocator, "size") == 3 * @sizeOf(Cell));
    std.debug.assert(@sizeOf(BumpAllocator) == 4 * @sizeOf(Cell));
}

// --- Tests ---

test "bump allocator aligns its start and tracks used and free bytes" {
    var backing: [4096]u8 align(16) = undefined;
    // Deliberately unaligned start: init must round it up to data_alignment.
    const base = @intFromPtr(&backing) + 8;
    var alloc = BumpAllocator.init(2048, base);
    const aligned = layouts.alignCell(base, layouts.data_alignment);
    try std.testing.expectEqual(aligned, alloc.here);
    try std.testing.expectEqual(aligned, alloc.start);
    try std.testing.expectEqual(base + 2048, alloc.end);
    try std.testing.expectEqual(base + 2048 - aligned, alloc.size);
    try std.testing.expectEqual(@as(Cell, 0), alloc.usedBytes());
    try std.testing.expectEqual(alloc.size, alloc.freeBytes());

    // Sizes are rounded up to the alignment; addresses are consecutive.
    const a = alloc.allocate(1);
    try std.testing.expectEqual(aligned, a);
    try std.testing.expectEqual(@as(Cell, 16), alloc.usedBytes());
    const b = alloc.allocate(17);
    try std.testing.expectEqual(aligned + 16, b);
    try std.testing.expectEqual(@as(Cell, 48), alloc.usedBytes());
    try std.testing.expectEqual(alloc.size - 48, alloc.freeBytes());

    // contains covers [start, end).
    try std.testing.expect(alloc.contains(@ptrFromInt(a)));
    try std.testing.expect(alloc.contains(@ptrFromInt(alloc.end - 16)));
    try std.testing.expect(!alloc.contains(@ptrFromInt(alloc.end)));
    try std.testing.expect(!alloc.contains(@ptrFromInt(alloc.start - 16)));
}

test "bump allocator canAllot honours the aligned size against end" {
    var backing: [1024]u8 align(16) = undefined;
    var alloc = BumpAllocator.init(256, @intFromPtr(&backing));
    try std.testing.expect(alloc.canAllot(0));
    try std.testing.expect(alloc.canAllot(256));
    try std.testing.expect(!alloc.canAllot(257));
    // 241 rounds up to 256, which still fits.
    try std.testing.expect(alloc.canAllot(241));
    _ = alloc.allocate(240);
    try std.testing.expectEqual(@as(Cell, 16), alloc.freeBytes());
    try std.testing.expect(alloc.canAllot(16));
    try std.testing.expect(alloc.canAllot(1));
    try std.testing.expect(!alloc.canAllot(17));
}

test "bump allocator reset and flush rewind here" {
    var backing: [512]u8 align(16) = undefined;
    var alloc = BumpAllocator.init(512, @intFromPtr(&backing));
    _ = alloc.allocate(100);
    try std.testing.expect(alloc.here != alloc.start);
    alloc.reset();
    try std.testing.expectEqual(alloc.start, alloc.here);
    try std.testing.expectEqual(@as(Cell, 0), alloc.usedBytes());

    _ = alloc.allocate(100);
    backing[0] = 0x00;
    backing[511] = 0x00;
    alloc.flush();
    try std.testing.expectEqual(alloc.start, alloc.here);
    if (std.debug.runtime_safety) {
        // Debug builds poison the whole region so stale references are noticed.
        try std.testing.expectEqual(@as(u8, 0xBA), backing[0]);
        try std.testing.expectEqual(@as(u8, 0xBA), backing[511]);
    }
}
