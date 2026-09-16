// primitives/misc.zig - Miscellaneous primitives
// exit, nano-count, sleep, size, ctrl-break

const std = @import("std");
const builtin = @import("builtin");

const layouts = @import("../layouts.zig");
const math = @import("../fixnum.zig");
const slot_visitor = @import("../slot_visitor.zig");
const vm_mod = @import("../vm.zig");

const Cell = layouts.Cell;
const VMAssemblyFields = vm_mod.VMAssemblyFields;

// --- Exit ---

pub export fn primitive_exit(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    // ( n -- )
    const top = vm.pop();
    if (!layouts.hasTag(top, .fixnum)) {
        std.c._exit(254);
    }
    const code = layouts.untagFixnum(top);
    // Use _exit instead of exit to avoid waiting for threads
    std.c._exit(@intCast(code));
}

// --- Nano Count ---

pub fn nanoCountMonotonic() u64 {
    // macOS: mach_absolute_time() scaled to nanoseconds
    // Linux: clock_gettime(CLOCK_MONOTONIC)
    if (comptime builtin.os.tag == .macos) {
        const mach = struct {
            extern "c" fn mach_absolute_time() u64;
            extern "c" fn mach_timebase_info(info: *MachTimebaseInfo) c_int;
            const MachTimebaseInfo = extern struct {
                numer: u32,
                denom: u32,
            };
            var scaling_factor: u64 = 0;
        };
        if (mach.scaling_factor == 0) {
            var info: mach.MachTimebaseInfo = undefined;
            _ = mach.mach_timebase_info(&info);
            mach.scaling_factor = @as(u64, info.numer) / @as(u64, info.denom);
        }
        return mach.mach_absolute_time() * mach.scaling_factor;
    } else {
        // Linux/generic: use CLOCK_MONOTONIC via C library
        var ts: std.c.timespec = undefined;
        if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
        return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
    }
}

pub export fn primitive_nano_count(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    // ( -- n )
    const now_u = nanoCountMonotonic();
    // Track monotonicity
    if (now_u < vm.last_nano_count) {
        vm.push(math.fromUnsignedCell(vm, vm.last_nano_count));
    } else {
        vm.last_nano_count = now_u;
        vm.push(math.fromUnsignedCell(vm, now_u));
    }
}

// --- Sleep ---

pub export fn primitive_sleep(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    // ( nanos -- )
    const nanos = layouts.untagFixnum(vm.pop());
    const secs = @divFloor(nanos, 1_000_000_000);
    const nsecs = @mod(nanos, 1_000_000_000);
    const ts = std.c.timespec{ .sec = @intCast(secs), .nsec = @intCast(nsecs) };
    _ = std.c.nanosleep(&ts, null);
}

// --- Size ---

pub export fn primitive_size(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    // ( obj -- n )
    const obj = vm.pop();
    if (layouts.isImmediate(obj)) {
        vm.push(layouts.tagFixnum(0));
    } else {
        // Use the canonical object-size computation the GC walks the heap with
        // (layouts.objectVisitInfoFromAddress). The old per-type switch here
        // fell through to a bare Object header for tuple/bignum/callstack,
        // reporting ~16 bytes for every tuple and bignum. Matches C++
        // object_size -> object::size (vm/objects.cpp).
        const size = slot_visitor.objectSize(layouts.UNTAG(obj));
        vm.push(layouts.tagFixnum(@intCast(size)));
    }
}

// --- Stub / Ctrl-Break ---

pub export fn primitive_stub(_: *VMAssemblyFields) callconv(.c) void {
    std.process.exit(1);
}

pub export fn primitive_enable_ctrl_break(vm_asm: *VMAssemblyFields) callconv(.c) void {
    // Matches C++ os-unix.cpp: a Ctrl-Break/SIGINT then raises a catchable
    // interrupt error (see safepoints.handleSafepoint) instead of entering FEP.
    vm_asm.getVM().stop_on_ctrl_break = true;
}

pub export fn primitive_disable_ctrl_break(vm_asm: *VMAssemblyFields) callconv(.c) void {
    vm_asm.getVM().stop_on_ctrl_break = false;
}

// --- Tests ---

const MiscTestVM = struct {
    vm: *vm_mod.FactorVM,
    heap: *@import("../data_heap.zig").DataHeap,

    fn init() !MiscTestVM {
        const data_heap_mod = @import("../data_heap.zig");
        const allocator = std.testing.allocator;
        const vm = try vm_mod.FactorVM.init(allocator);
        vm.vm_asm.ctx = try vm.newContext();
        vm.vm_asm.spare_ctx = try vm.newContext();
        const heap = try data_heap_mod.DataHeap.init(allocator, 256 * 1024, 64 * 1024, 64 * 1024);
        vm.setDataHeap(heap);
        return .{ .vm = vm, .heap = heap };
    }

    fn deinit(self: *MiscTestVM) void {
        self.heap.deinit();
        self.vm.cards_array = null;
        self.vm.decks_array = null;
        self.vm.deinit();
    }
};

test "nanoCountMonotonic is positive and never goes backwards" {
    const a = nanoCountMonotonic();
    try std.testing.expect(a > 0);
    var i: usize = 0;
    var prev = a;
    while (i < 100) : (i += 1) {
        const now = nanoCountMonotonic();
        try std.testing.expect(now >= prev);
        prev = now;
    }
}

test "primitive_nano_count pushes a non-decreasing integer" {
    const bignum = @import("../bignum.zig");
    var t = try MiscTestVM.init();
    defer t.deinit();

    primitive_nano_count(&t.vm.vm_asm);
    const first = t.vm.pop();
    primitive_nano_count(&t.vm.vm_asm);
    const second = t.vm.pop();
    try std.testing.expect(math.toUnsignedCell(t.vm, second) >= math.toUnsignedCell(t.vm, first));
    try std.testing.expectEqual(math.toUnsignedCell(t.vm, second), t.vm.last_nano_count);

    // A clock that appears to go backwards is clamped to the last value.
    t.vm.last_nano_count = std.math.maxInt(u64);
    primitive_nano_count(&t.vm.vm_asm);
    const clamped = t.vm.pop();
    try std.testing.expect(layouts.hasTag(clamped, .bignum));
    const bn: *const bignum.Bignum = @ptrFromInt(layouts.UNTAG(clamped));
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), bignum.toUint64(bn));
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), t.vm.last_nano_count);
}

test "primitive_sleep waits at least the requested nanoseconds" {
    var t = try MiscTestVM.init();
    defer t.deinit();
    const before = nanoCountMonotonic();
    t.vm.push(layouts.tagFixnum(2_000_000));
    primitive_sleep(&t.vm.vm_asm);
    const after = nanoCountMonotonic();
    try std.testing.expect(after - before >= 2_000_000);
    try std.testing.expectEqual(t.vm.vm_asm.ctx.datastack, t.vm.vm_asm.ctx.datastack);
}

test "primitive_size reports zero for immediates and the aligned size for heap objects" {
    const float_mod = @import("../float.zig");
    var t = try MiscTestVM.init();
    defer t.deinit();

    const Case = struct { obj: Cell, size: Cell };
    const arr = t.vm.allotArray(3, layouts.false_object) orelse return error.OutOfMemory;
    const ba = t.vm.allotByteArray(5);
    const boxed = try float_mod.allocBoxedFloat(t.vm, 1.5);
    const cases = [_]Case{
        .{ .obj = layouts.tagFixnum(7), .size = 0 },
        .{ .obj = layouts.false_object, .size = 0 },
        .{ .obj = arr, .size = layouts.alignCell(@sizeOf(layouts.Array) + 3 * @sizeOf(Cell), layouts.data_alignment) },
        .{ .obj = ba, .size = layouts.alignCell(@sizeOf(layouts.ByteArray) + 5, layouts.data_alignment) },
        .{ .obj = layouts.tagFloat(boxed), .size = layouts.alignCell(@sizeOf(layouts.BoxedFloat), layouts.data_alignment) },
    };
    for (cases) |c| {
        t.vm.push(c.obj);
        primitive_size(&t.vm.vm_asm);
        try std.testing.expectEqual(layouts.tagFixnum(@intCast(c.size)), t.vm.pop());
        if (!layouts.isImmediate(c.obj)) {
            try std.testing.expectEqual(c.size, slot_visitor.objectSize(layouts.UNTAG(c.obj)));
        }
    }
}

test "ctrl-break primitives toggle the VM flag" {
    var t = try MiscTestVM.init();
    defer t.deinit();
    try std.testing.expect(!t.vm.stop_on_ctrl_break);
    primitive_enable_ctrl_break(&t.vm.vm_asm);
    try std.testing.expect(t.vm.stop_on_ctrl_break);
    primitive_enable_ctrl_break(&t.vm.vm_asm);
    try std.testing.expect(t.vm.stop_on_ctrl_break);
    primitive_disable_ctrl_break(&t.vm.vm_asm);
    try std.testing.expect(!t.vm.stop_on_ctrl_break);
}
