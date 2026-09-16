// segments.zig - Memory segment management

const std = @import("std");
const builtin = @import("builtin");
const layouts = @import("layouts.zig");
const Cell = layouts.Cell;

// On x86_64-macos under Rosetta, getpagesize() returns 4096 even though
// system call performance characteristics.
pub const page_size: usize = if (builtin.cpu.arch == .x86_64 and builtin.os.tag == .macos)
    4096
else
    std.heap.page_size_min;

// The start/end fields point to the usable memory region
pub const Segment = struct {
    start: Cell,
    size: Cell,
    end: Cell,

    // Track total allocation for proper cleanup
    alloc_base: Cell,
    alloc_size: Cell,

    // Extra low guard pages for callstack segments. Unlocked during GC to provide
    // stack headroom. The Zig debug build uses substantially more native stack
    pub const low_guard_pages: usize = 64;

    // Conservative estimate of max stack usage during GC.
    // Used to decide whether guard page unlock is needed before GC.
    // Debug: large frames (~2.5KB each) × ~20 deep + sort buffer (~8KB) ≈ 60KB
    // Release: small frames (~200B each) × ~20 deep + sort buffer (~8KB) ≈ 12KB
    pub const gc_stack_headroom: usize = 65536;

    // Initialize with optional executable flag
    pub fn init(size_param: Cell, executable: bool) !Segment {
        return initWithGuardPages(size_param, executable, 1);
    }

    // Initialize with a specified number of low guard pages.
    // Extra low guard pages can be unlocked during GC for stack headroom.
    pub fn initWithGuardPages(size_param: Cell, executable: bool, num_low_guard_pages: usize) !Segment {
        // Page-align size to ensure guard pages work (mprotect requires page alignment)
        const size = layouts.alignCell(size_param, page_size);

        const prot: std.c.PROT = if (executable)
            .{ .READ = true, .WRITE = true, .EXEC = true }
        else
            .{ .READ = true, .WRITE = true };

        // Allocate: [low guard pages][usable memory][high guard page]
        const low_guard_size = num_low_guard_pages * page_size;
        const alloc_size = low_guard_size + size + page_size;

        // On ARM64 macOS, executable memory requires MAP_JIT flag
        const is_arm64_macos = builtin.cpu.arch == .aarch64 and
            (builtin.os.tag == .macos or builtin.os.tag == .ios);

        const map_flags: std.c.MAP = if (executable and is_arm64_macos)
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .JIT = true }
        else
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true };

        const ptr = std.c.mmap(
            null,
            alloc_size,
            prot,
            map_flags,
            -1,
            0,
        );
        if (ptr == std.c.MAP_FAILED) return error.OutOfMemory;

        // On ARM64 macOS with MAP_JIT, need to disable write protection for initial writes
        if (executable and is_arm64_macos) {
            const pthread_jit_write_protect_np = struct {
                extern "c" fn pthread_jit_write_protect_np(enabled: c_int) void;
            }.pthread_jit_write_protect_np;
            pthread_jit_write_protect_np(0); // Disable write protection (allow writes)
        }

        const alloc_base = @intFromPtr(ptr);

        // Usable memory starts after low guard pages
        const start = alloc_base + low_guard_size;
        const end = start + size;

        var seg = Segment{
            .start = start,
            .size = size,
            .end = end,
            .alloc_base = alloc_base,
            .alloc_size = alloc_size,
        };

        // Lock the guard pages (make them inaccessible)
        // Note: On ARM64 macOS with MAP_JIT, mprotect doesn't work on JIT memory,
        // so we skip guard page setup for executable segments
        if (!(executable and is_arm64_macos)) {
            seg.setBorderLocked(true) catch {
                // Cleanup on failure
                _ = std.c.munmap(@ptrFromInt(alloc_base), alloc_size);
                return error.MprotectFailed;
            };
        }

        return seg;
    }

    pub fn deinit(self: *Segment) void {
        if (self.alloc_size > 0) {
            _ = std.c.munmap(@ptrFromInt(self.alloc_base), self.alloc_size);
        }
        self.start = 0;
        self.size = 0;
        self.end = 0;
        self.alloc_base = 0;
        self.alloc_size = 0;
    }

    pub fn isUnderflow(self: *const Segment, addr: Cell) bool {
        // Uses alloc_base to cover extended guard areas (multiple low guard pages)
        return addr >= self.alloc_base and addr < self.start;
    }

    pub fn isOverflow(self: *const Segment, addr: Cell) bool {
        return addr >= self.end and addr < (self.end + page_size);
    }

    // Check if address is in the usable segment
    pub fn contains(self: *const Segment, addr: Cell) bool {
        return addr >= self.start and addr < self.end;
    }

    // Locks/unlocks ALL low guard pages (alloc_base to start) and the high guard page.
    pub fn setBorderLocked(self: *Segment, locked: bool) !void {
        const prot: std.c.PROT = if (locked)
            .{}
        else
            .{ .READ = true, .WRITE = true };

        // Low guard area (may be multiple pages)
        const lo_size = self.start - self.alloc_base;
        if (lo_size > 0) {
            const lo_ptr: *align(std.heap.page_size_min) anyopaque = @ptrFromInt(self.alloc_base);
            if (std.c.mprotect(lo_ptr, lo_size, prot) != 0) return error.MprotectFailed;
        }

        // High guard page
        const hi = self.end;
        const hi_ptr: *align(std.heap.page_size_min) anyopaque = @ptrFromInt(hi);
        if (std.c.mprotect(hi_ptr, page_size, prot) != 0) return error.MprotectFailed;
    }
};

// --- Tests ---

test "segment places one guard page below and above a page-aligned region" {
    var seg = try Segment.init(1000, false);
    defer seg.deinit();

    try std.testing.expectEqual(page_size, seg.size);
    try std.testing.expectEqual(seg.alloc_base + page_size, seg.start);
    try std.testing.expectEqual(seg.start + seg.size, seg.end);
    try std.testing.expectEqual(3 * page_size, seg.alloc_size);
    try std.testing.expectEqual(@as(Cell, 0), seg.start % page_size);

    try std.testing.expect(seg.contains(seg.start));
    try std.testing.expect(seg.contains(seg.end - 1));
    try std.testing.expect(!seg.contains(seg.end));
    try std.testing.expect(!seg.contains(seg.start - 1));

    try std.testing.expect(seg.isUnderflow(seg.alloc_base));
    try std.testing.expect(seg.isUnderflow(seg.start - 1));
    try std.testing.expect(!seg.isUnderflow(seg.start));
    try std.testing.expect(!seg.isUnderflow(seg.alloc_base - 1));

    try std.testing.expect(seg.isOverflow(seg.end));
    try std.testing.expect(seg.isOverflow(seg.end + page_size - 1));
    try std.testing.expect(!seg.isOverflow(seg.end + page_size));
    try std.testing.expect(!seg.isOverflow(seg.end - 1));

    // The usable region is readable and writable end to end.
    const first: *Cell = @ptrFromInt(seg.start);
    const last: *Cell = @ptrFromInt(seg.end - @sizeOf(Cell));
    first.* = 0x1234;
    last.* = 0x5678;
    try std.testing.expectEqual(@as(Cell, 0x1234), first.*);
    try std.testing.expectEqual(@as(Cell, 0x5678), last.*);
}

test "segment size is rounded up to whole pages" {
    var seg = try Segment.init(page_size + 1, false);
    defer seg.deinit();
    try std.testing.expectEqual(2 * page_size, seg.size);
    try std.testing.expectEqual(4 * page_size, seg.alloc_size);

    var exact = try Segment.init(page_size, false);
    defer exact.deinit();
    try std.testing.expectEqual(page_size, exact.size);
}

test "segment with extra low guard pages reports underflow across all of them" {
    var seg = try Segment.initWithGuardPages(page_size, false, 4);
    defer seg.deinit();
    try std.testing.expectEqual(4 * page_size, seg.start - seg.alloc_base);
    try std.testing.expectEqual(6 * page_size, seg.alloc_size);
    try std.testing.expect(seg.isUnderflow(seg.alloc_base));
    try std.testing.expect(seg.isUnderflow(seg.alloc_base + 2 * page_size));
    try std.testing.expect(seg.isUnderflow(seg.start - 1));
    try std.testing.expect(!seg.isUnderflow(seg.start));
    try std.testing.expect(seg.contains(seg.start));
}

test "segment guard pages can be unlocked and locked again" {
    var seg = try Segment.initWithGuardPages(page_size, false, 2);
    defer seg.deinit();
    try seg.setBorderLocked(false);
    try seg.setBorderLocked(true);
    // The usable region is unaffected either way.
    const p: *Cell = @ptrFromInt(seg.start);
    p.* = 42;
    try std.testing.expectEqual(@as(Cell, 42), p.*);
}

test "executable segment is writable" {
    var seg = try Segment.init(page_size, true);
    defer seg.deinit();
    const bytes: [*]u8 = @ptrFromInt(seg.start);
    bytes[0] = 0xC3;
    bytes[seg.size - 1] = 0x90;
    try std.testing.expectEqual(@as(u8, 0xC3), bytes[0]);
    try std.testing.expectEqual(@as(u8, 0x90), bytes[seg.size - 1]);
}

test "segment deinit clears every field and is idempotent" {
    var seg = try Segment.init(page_size, false);
    seg.deinit();
    try std.testing.expectEqual(@as(Cell, 0), seg.start);
    try std.testing.expectEqual(@as(Cell, 0), seg.size);
    try std.testing.expectEqual(@as(Cell, 0), seg.end);
    try std.testing.expectEqual(@as(Cell, 0), seg.alloc_base);
    try std.testing.expectEqual(@as(Cell, 0), seg.alloc_size);
    try std.testing.expect(!seg.contains(0));
    seg.deinit();
}
