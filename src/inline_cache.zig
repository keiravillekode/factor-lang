const std = @import("std");
const builtin = @import("builtin");

const code_blocks = @import("code_blocks.zig");
const icache = @import("icache.zig");
const jit_protect = @import("jit_protect.zig");
const jit = @import("jit.zig");
const layouts = @import("layouts.zig");
const objects = @import("objects.zig");
const dispatch = @import("primitives/code.zig");
const vm_mod = @import("vm.zig");

const Cell = layouts.Cell;
const Fixnum = layouts.Fixnum;
const FactorVM = vm_mod.FactorVM;

// PIC type - determined by the types of objects being dispatched on
pub const PicType = enum {
    tag, // Dispatch on type tag (fixnum, string, array, etc.)
    tuple, // Dispatch on tuple layout
};

// Inline cache JIT - generates PIC code
pub const InlineCacheJit = struct {
    base_jit: jit.Jit,
    pic_type: PicType,

    const Self = @This();

    pub fn init(vm: *FactorVM, pic_type: PicType, generic_word: Cell) Self {
        return Self{
            .base_jit = jit.Jit.init(vm, generic_word),
            .pic_type = pic_type,
        };
    }

    pub fn registerRoot(self: *Self) void {
        self.base_jit.registerRoot();
    }

    pub fn deinit(self: *Self) void {
        self.base_jit.deinit();
    }

    pub fn emitCheckAndJump(self: *Self, ic_type: PicType, i: Cell, klass_in: Cell, method_in: Cell) !void {
        const vm = self.base_jit.vm;

        var klass = klass_in;
        var method = method_in;
        vm.data_roots.appendAssumeCapacity(&klass);
        defer _ = vm.data_roots.pop();
        vm.data_roots.appendAssumeCapacity(&method);
        defer _ = vm.data_roots.pop();

        const check_template: jit.JitTemplate = if (layouts.hasTag(klass, .fixnum))
            .pic_check_tag
        else
            .pic_check_tuple;

        if (!(i == 0 and ic_type == .tag and klass == 0)) {
            try self.base_jit.emitWithLiteral(check_template, klass);
        }

        try self.base_jit.emitWithLiteral(.pic_hit, method);
    }

    pub fn emitMissHandler(self: *Self, generic_word: *Cell, methods: *Cell, index: Cell, cache_entries: *Cell, tail_call: bool) !void {
        try self.base_jit.emit(.prolog);

        try self.base_jit.push(generic_word.*);
        try self.base_jit.push(methods.*);
        try self.base_jit.push(layouts.tagFixnum(@intCast(index)));
        try self.base_jit.push(cache_entries.*);

        const vm = self.base_jit.vm;
        const miss_word = if (tail_call)
            vm.vm_asm.special_objects[@intFromEnum(objects.SpecialObject.pic_miss_tail_word)]
        else
            vm.vm_asm.special_objects[@intFromEnum(objects.SpecialObject.pic_miss_word)];

        _ = try self.base_jit.emitSubprimitive(miss_word, true, true);
    }

    pub fn emitInlineCache(
        self: *Self,
        index: Fixnum,
        generic_word_in: Cell,
        methods_in: Cell,
        cache_entries_in: Cell,
        tail_call: bool,
    ) !void {
        const vm = self.base_jit.vm;

        var generic_word = generic_word_in;
        var methods = methods_in;
        var cache_entries = cache_entries_in;
        vm.data_roots.appendAssumeCapacity(&generic_word);
        defer _ = vm.data_roots.pop();
        vm.data_roots.appendAssumeCapacity(&methods);
        defer _ = vm.data_roots.pop();
        vm.data_roots.appendAssumeCapacity(&cache_entries);
        defer _ = vm.data_roots.pop();

        if (self.pic_type == .tag) {
            vm.dispatch_stats.pic_tag_count += 1;
        } else {
            vm.dispatch_stats.pic_tuple_count += 1;
        }

        const byte_offset: Fixnum = -index * @as(Fixnum, @sizeOf(Cell));
        try self.base_jit.emitWithLiteral(.pic_load, layouts.tagFixnum(byte_offset));

        switch (self.pic_type) {
            .tag => try self.base_jit.emit(.pic_tag),
            .tuple => try self.base_jit.emit(.pic_tuple),
        }

        if (cache_entries != layouts.false_object and
            layouts.hasTag(cache_entries, .array))
        {
            const entries: *const layouts.Array = @ptrFromInt(layouts.UNTAG(cache_entries));
            const data = entries.data();
            const entry_count = blk: {
                break :blk layouts.untagFixnumUnsigned(entries.capacity);
            };

            var i: Cell = 0;
            while (i + 1 < entry_count) : (i += 2) {
                const klass = data[i];
                const method = data[i + 1];

                // Validate method is word or quotation
                const mt = layouts.typeTag(method);
                std.debug.assert(mt == .word or mt == .quotation);

                try self.emitCheckAndJump(self.pic_type, i, klass, method);
            }
        }

        try self.emitMissHandler(&generic_word, &methods, @intCast(index), &cache_entries, tail_call);
    }
};

// Handle inline cache miss
pub fn inlineCacheMiss(vm: *FactorVM, return_address: Cell) Cell {
    var jit_scope = jit_protect.Scope.init();
    defer jit_scope.deinit();

    var return_root = vm_mod.CodeRoot.init(return_address, vm);
    return_root.register();
    defer return_root.deinit();

    const ctx = vm.vm_asm.ctx;
    const tail_call_p = CallSitePatcher.isTailCallSite(return_root.value);

    // Pop parameters from the data stack (pushed by the miss handler in JIT code)
    var cache_entries = ctx.pop();
    const index_tagged = ctx.pop();
    var methods = ctx.pop();
    var generic_word = ctx.pop();

    // Register heap pointers as GC roots — batch capacity for all 4 roots
    vm.data_roots.appendAssumeCapacity(&cache_entries);
    defer _ = vm.data_roots.pop();
    vm.data_roots.appendAssumeCapacity(&methods);
    defer _ = vm.data_roots.pop();
    vm.data_roots.appendAssumeCapacity(&generic_word);
    defer _ = vm.data_roots.pop();

    if (comptime builtin.mode == .Debug) {
        std.debug.assert(layouts.hasTag(index_tagged, .fixnum));
        std.debug.assert(layouts.hasTag(generic_word, .word));
    }

    const index: Fixnum = layouts.untagFixnum(index_tagged);

    const obj_addr = ctx.datastack -% @as(Cell, @intCast(index * @as(Fixnum, @sizeOf(Cell))));

    var obj: Cell = @as(*const Cell, @ptrFromInt(obj_addr)).*;
    vm.data_roots.appendAssumeCapacity(&obj);
    defer _ = vm.data_roots.pop();

    // Determine current PIC size
    var pic_size: Cell = 0;
    if (cache_entries != layouts.false_object and layouts.hasTag(cache_entries, .array)) {
        const entries: *const layouts.Array = @ptrFromInt(layouts.UNTAG(cache_entries));
        pic_size = layouts.untagFixnumUnsigned(entries.capacity) / 2;
    }

    updatePicTransitions(vm, pic_size);

    // Default to generic word's entry point
    const generic: *const layouts.Word = @ptrFromInt(layouts.UNTAG(generic_word));
    var xt: Cell = generic.entry_point;

    if (pic_size < vm.max_pic_size) {
        if (comptime builtin.mode == .Debug) {
            std.debug.assert(layouts.TAG(obj) < layouts.type_count);
        }

        const method_lookup = dispatch.lookupMethodAndClass(obj, methods);

        if (method_lookup.method != layouts.false_object) {
            if (comptime builtin.mode == .Debug) {
                const method_tag = layouts.typeTag(method_lookup.method);
                std.debug.assert(method_tag == .word or method_tag == .quotation);
            }

            const maybe_new_entries = addInlineCacheEntry(vm, cache_entries, method_lookup.klass, method_lookup.method);

            if (maybe_new_entries) |new_entries_value| {
                var new_cache_entries: Cell = new_entries_value;
                vm.data_roots.appendAssumeCapacity(&new_cache_entries);
                defer _ = vm.data_roots.pop();

                const new_xt = generateInlineCache(vm, index, generic_word, methods, new_cache_entries, tail_call_p);
                if (new_xt != 0) {
                    xt = new_xt;
                }
            }
        }
    }

    // Patch the call site
    if (return_root.valid and return_root.value != 0 and xt != 0) {
        if (comptime builtin.mode == .Debug) {
            std.debug.assert(CallSitePatcher.isValidCallSite(return_root.value));
        }
        const current_target = CallSitePatcher.getCallTarget(return_root.value);
        if (current_target != xt) {
            deallocateInlineCache(vm, return_root.value);
            CallSitePatcher.setCallTarget(return_root.value, xt);
        }
    }

    return xt;
}

fn updatePicTransitions(vm: *FactorVM, pic_size: Cell) void {
    if (pic_size == vm.max_pic_size) {
        vm.dispatch_stats.pic_to_mega_transitions += 1;
    } else if (pic_size == 0) {
        vm.dispatch_stats.cold_call_to_ic_transitions += 1;
    } else if (pic_size == 1) {
        vm.dispatch_stats.ic_to_pic_transitions += 1;
    }
}

fn deallocateInlineCache(vm: *FactorVM, return_address: Cell) void {
    const old_entry_point = if (comptime builtin.mode == .Debug) blk: {
        break :blk CallSitePatcher.getCallTarget(return_address);
    } else blk: {
        break :blk CallSitePatcher.getCallTargetUnchecked(return_address);
    };
    if (old_entry_point == 0) return;

    const old_block_addr = old_entry_point - @sizeOf(code_blocks.CodeBlock);
    const old_block: *code_blocks.CodeBlock = @ptrFromInt(old_block_addr);

    if (old_block.isPic()) {
        if (vm.code) |code_heap| {
            code_heap.free(old_block);
        }
    }
}

pub fn addInlineCacheEntry(vm: *FactorVM, cache_entries: Cell, klass: Cell, method: Cell) ?Cell {
    var klass_copy = klass;
    var method_copy = method;
    var entries_copy = cache_entries;

    vm.data_roots.appendAssumeCapacity(&klass_copy);
    defer _ = vm.data_roots.pop();
    vm.data_roots.appendAssumeCapacity(&method_copy);
    defer _ = vm.data_roots.pop();
    vm.data_roots.appendAssumeCapacity(&entries_copy);
    defer _ = vm.data_roots.pop();

    if (entries_copy == layouts.false_object) {
        const new_array_cell = vm.allotUninitializedArray(2) orelse return null;
        const new_array: *layouts.Array = @ptrFromInt(layouts.UNTAG(new_array_cell));
        const arr_data = new_array.data();
        arr_data[0] = klass_copy;
        arr_data[1] = method_copy;
        return new_array_cell;
    }

    std.debug.assert(layouts.hasTag(entries_copy, .array));

    const old_entries: *layouts.Array = @ptrFromInt(layouts.UNTAG(entries_copy));
    const old_size = layouts.untagFixnumUnsigned(old_entries.capacity);
    const old_data = old_entries.data();

    var i: Cell = 0;
    while (i < old_size) : (i += 2) {
        if (old_data[i] == klass_copy) {
            if (old_data[i + 1] == method_copy) {
                return null;
            }
            old_data[i + 1] = method_copy;
            vm.writeBarrierKnownHeap(&old_data[i]);
            return entries_copy;
        }
    }

    const new_size = old_size + 2;

    const new_array_cell = vm.allotUninitializedArray(new_size) orelse return null;
    const old_entries_live: *layouts.Array = @ptrFromInt(layouts.UNTAG(entries_copy));
    const old_data_live = old_entries_live.data();
    const new_array: *layouts.Array = @ptrFromInt(layouts.UNTAG(new_array_cell));
    const new_data = new_array.data();

    @memcpy(new_data[0..old_size], old_data_live[0..old_size]);

    new_data[old_size] = klass_copy;
    new_data[old_size + 1] = method_copy;

    return new_array_cell;
}

fn generateInlineCache(vm: *FactorVM, index: Fixnum, generic_word_in: Cell, methods_in: Cell, cache_entries_in: Cell, tail_call_p: bool) Cell {
    var generic_word = generic_word_in;
    var methods = methods_in;
    var cache_entries = cache_entries_in;
    vm.data_roots.appendAssumeCapacity(&generic_word);
    defer _ = vm.data_roots.pop();
    vm.data_roots.appendAssumeCapacity(&methods);
    defer _ = vm.data_roots.pop();
    vm.data_roots.appendAssumeCapacity(&cache_entries);
    defer _ = vm.data_roots.pop();

    const ic_type = determineInlineCacheType(cache_entries);
    var ic_jit = InlineCacheJit.init(vm, ic_type, generic_word);
    ic_jit.registerRoot();
    ic_jit.base_jit.owner = generic_word;
    defer ic_jit.deinit();

    ic_jit.emitInlineCache(index, generic_word, methods, cache_entries, tail_call_p) catch {
        return 0;
    };

    const code_block = ic_jit.base_jit.toCodeBlock(.pic, jit.JIT_FRAME_SIZE) catch {
        return 0;
    };

    if (code_block) |block| {
        vm.initializeCodeBlockFromMap(block);
        return block.entryPoint();
    }

    return 0;
}

/// Hash a class into a mega-cache pair index (even slot). Live miss path is
/// primitives/code.updateMethodCache; lookup/update helpers were never wired.
pub fn megaCacheHashcode(klass: Cell, capacity_mask: Cell) Cell {
    return ((klass >> layouts.tag_bits) & capacity_mask) << 1;
}

// Call site patching for supported JIT backends.
pub const CallSitePatcher = struct {
    const call_opcode: u8 = 0xe8;
    const jmp_opcode: u8 = 0xe9;
    const arm_b_mask: u32 = 0x7c000000;
    const arm_b_pattern: u32 = 0x14000000;

    fn x86CallSiteOpcode(return_address: Cell) u8 {
        const opcode_ptr: *const u8 = @ptrFromInt(return_address - 5);
        return opcode_ptr.*;
    }

    fn armCallSiteInsn(return_address: Cell) u32 {
        const insn_ptr: *align(1) const u32 = @ptrFromInt(return_address - 4);
        return insn_ptr.*;
    }

    fn isValidCallSite(return_address: Cell) bool {
        return switch (builtin.cpu.arch) {
            .x86, .x86_64 => blk: {
                const opcode = x86CallSiteOpcode(return_address);
                break :blk opcode == call_opcode or opcode == jmp_opcode;
            },
            .aarch64 => (armCallSiteInsn(return_address) & arm_b_mask) == arm_b_pattern,
            else => @compileError("Unsupported architecture for call site patching"),
        };
    }

    pub fn getCallTarget(return_address: Cell) Cell {
        if (!isValidCallSite(return_address)) {
            return 0;
        }

        return getCallTargetUnchecked(return_address);
    }

    pub fn getCallTargetUnchecked(return_address: Cell) Cell {
        return switch (builtin.cpu.arch) {
            .x86, .x86_64 => blk: {
                const offset_ptr: *align(1) const i32 = @ptrFromInt(return_address - 4);
                const offset: i64 = offset_ptr.*;
                break :blk @intCast(@as(i64, @intCast(return_address)) + offset);
            },
            .aarch64 => blk: {
                const insn: i32 = @bitCast(armCallSiteInsn(return_address));
                const offset: i64 = (insn & 0x03ffffff) << 6 >> 4;
                // AArch64 branch immediates are relative to the branch instruction,
                // while callers pass the address of the following instruction.
                break :blk @intCast(@as(i64, @intCast(return_address)) + offset - 4);
            },
            else => @compileError("Unsupported architecture for call site patching"),
        };
    }

    pub fn setCallTarget(return_address: Cell, target: Cell) void {
        switch (builtin.cpu.arch) {
            .x86, .x86_64 => {
                const offset: i32 = @truncate(@as(i64, @intCast(target)) - @as(i64, @intCast(return_address)));
                const offset_ptr: *align(1) i32 = @ptrFromInt(return_address - 4);
                offset_ptr.* = offset;
            },
            .aarch64 => {
                const delta = @as(i64, @intCast(target)) - @as(i64, @intCast(return_address)) + 4;
                std.debug.assert((delta & 3) == 0);
                std.debug.assert(delta >= -0x8000000);
                std.debug.assert(delta < 0x8000000);

                const insn_ptr: *align(1) u32 = @ptrFromInt(return_address - 4);
                const insn = insn_ptr.*;
                const imm26: u32 = @truncate(@as(u64, @bitCast(@divTrunc(delta, 4))));
                insn_ptr.* = (insn & 0xfc000000) | (imm26 & 0x03ffffff);
                icache.flushICache(return_address - 4, 4);
            },
            else => @compileError("Unsupported architecture for call site patching"),
        }
    }

    pub fn isTailCallSite(return_address: Cell) bool {
        return switch (builtin.cpu.arch) {
            .x86, .x86_64 => x86CallSiteOpcode(return_address) == jmp_opcode,
            .aarch64 => (armCallSiteInsn(return_address) >> 31) == 0,
            else => @compileError("Unsupported architecture for call site patching"),
        };
    }
};

pub fn determineInlineCacheType(cache_entries: Cell) PicType {
    if (cache_entries == layouts.false_object) {
        return .tag;
    }

    std.debug.assert(layouts.hasTag(cache_entries, .array));

    const entries: *const layouts.Array = @ptrFromInt(layouts.UNTAG(cache_entries));
    const entry_count = layouts.untagFixnumUnsigned(entries.capacity);
    const data = entries.data();

    var i: Cell = 0;
    while (i < entry_count) : (i += 2) {
        const klass = data[i];
        if (layouts.hasTag(klass, .array)) {
            return .tuple;
        }
    }

    return .tag;
}

// Tests
test "object class" {
    const fixnum = layouts.tagFixnum(42);
    const fixnum_class = dispatch.objectClass(fixnum);
    try std.testing.expectEqual(layouts.tagFixnum(0), fixnum_class);
}

test "megamorphic cache hashcode" {
    const klass = layouts.tagFixnum(5);
    const capacity_mask: Cell = 14;
    const slot = megaCacheHashcode(klass, capacity_mask);
    try std.testing.expect(slot < 16);
    try std.testing.expect(slot % 2 == 0);
}

test "call site patcher" {
    switch (builtin.cpu.arch) {
        .x86, .x86_64 => {
            var x86_call = [_]u8{ 0xe8, 0, 0, 0, 0 };
            const call_return_address = @intFromPtr(&x86_call[4]) + 1;
            try std.testing.expect(CallSitePatcher.isValidCallSite(call_return_address));
            try std.testing.expect(!CallSitePatcher.isTailCallSite(call_return_address));
            try std.testing.expectEqual(call_return_address, CallSitePatcher.getCallTarget(call_return_address));

            const call_target = call_return_address + 16;
            CallSitePatcher.setCallTarget(call_return_address, call_target);
            try std.testing.expectEqual(call_target, CallSitePatcher.getCallTarget(call_return_address));

            var x86_jmp = [_]u8{ 0xe9, 0, 0, 0, 0 };
            const jmp_return_address = @intFromPtr(&x86_jmp[4]) + 1;
            try std.testing.expect(CallSitePatcher.isValidCallSite(jmp_return_address));
            try std.testing.expect(CallSitePatcher.isTailCallSite(jmp_return_address));
        },
        .aarch64 => {
            var arm_bl = [_]u8{ 0, 0, 0, 0 };
            std.mem.writeInt(u32, arm_bl[0..4], 0x94000000, .little);
            const bl_return_address = @intFromPtr(&arm_bl[0]) + 4;
            try std.testing.expect(CallSitePatcher.isValidCallSite(bl_return_address));
            try std.testing.expect(!CallSitePatcher.isTailCallSite(bl_return_address));
            try std.testing.expectEqual(bl_return_address - 4, CallSitePatcher.getCallTarget(bl_return_address));

            const bl_target = bl_return_address + 16;
            CallSitePatcher.setCallTarget(bl_return_address, bl_target);
            try std.testing.expectEqual(bl_target, CallSitePatcher.getCallTarget(bl_return_address));

            var arm_b = [_]u8{ 0, 0, 0, 0 };
            std.mem.writeInt(u32, arm_b[0..4], 0x14000000, .little);
            const b_return_address = @intFromPtr(&arm_b[0]) + 4;
            try std.testing.expect(CallSitePatcher.isValidCallSite(b_return_address));
            try std.testing.expect(CallSitePatcher.isTailCallSite(b_return_address));
            try std.testing.expectEqual(b_return_address - 4, CallSitePatcher.getCallTarget(b_return_address));
        },
        else => return error.SkipZigTest,
    }
}

// --- Tests over a bare VM with data and code heaps (see jit.test_support) ---

const ts = jit.test_support;
const testing = std.testing;

/// One-byte marker templates so PIC code reads as a string of template
/// letters, plus miss-handler words whose subprimitive emits "Z" / "Y".
fn installPicMarkers(f: *ts.Fixture) void {
    f.install(.jit_prolog, &.{}, "P");
    f.install(.jit_push_literal, &.{}, "L");
    f.install(.pic_load, &.{}, "O");
    f.install(.pic_tag, &.{}, "T");
    f.install(.pic_tuple, &.{}, "V");
    f.install(.pic_check_tag, &.{}, "K");
    f.install(.pic_check_tuple, &.{}, "U");
    f.install(.pic_hit, &.{}, "H");
    const miss = f.template(&.{}, "Z");
    f.setSpecial(.pic_miss_word, f.word(f.array(&.{ layouts.false_object, layouts.false_object, miss })));
    const miss_tail = f.template(&.{}, "Y");
    f.setSpecial(.pic_miss_tail_word, f.word(f.array(&.{ layouts.false_object, layouts.false_object, miss_tail })));
}

test "inline cache jit emits tag checks, hits and the miss handler" {
    var f: ts.Fixture = undefined;
    try f.init();
    defer f.deinit();
    installPicMarkers(&f);

    const generic = f.word(layouts.false_object);
    const m1 = f.word(layouts.false_object);
    const m2 = f.quotation(&.{});
    const methods = f.array(&.{ layouts.false_object, layouts.false_object });
    // Class 0 (fixnum) in the first slot of a tag PIC needs no check.
    const entries = f.array(&.{ layouts.tagFixnum(0), m1, layouts.tagFixnum(3), m2 });

    var ic = InlineCacheJit.init(f.vm, .tag, generic);
    ic.registerRoot();
    defer ic.deinit();
    try ic.emitInlineCache(1, generic, methods, entries, false);

    try testing.expectEqualSlices(u8, "OTHKHPLLLLZ", ic.base_jit.code.items);
    try testing.expectEqualSlices(Cell, &.{
        layouts.tagFixnum(-1 * @sizeOf(Cell)), m1,      layouts.tagFixnum(3), m2,
        generic,                               methods, layouts.tagFixnum(1), entries,
    }, ts.items(&ic.base_jit.literals));
    try testing.expectEqual(@as(u64, 1), f.vm.dispatch_stats.pic_tag_count);
    try testing.expectEqual(@as(u64, 0), f.vm.dispatch_stats.pic_tuple_count);
}

test "inline cache jit: tuple PIC, tail-call miss handler and empty cache" {
    var f: ts.Fixture = undefined;
    try f.init();
    defer f.deinit();
    installPicMarkers(&f);
    const generic = f.word(layouts.false_object);
    const m1 = f.word(layouts.false_object);
    const methods = f.array(&.{layouts.false_object});
    const layout = f.array(&.{ layouts.tagFixnum(1), layouts.tagFixnum(0), layouts.tagFixnum(0) });

    {
        // A tuple layout class always gets a tuple check, and a tail-call
        // site uses the tail miss word.
        const entries = f.array(&.{ layout, m1 });
        var ic = InlineCacheJit.init(f.vm, .tuple, generic);
        ic.registerRoot();
        defer ic.deinit();
        try ic.emitInlineCache(0, generic, methods, entries, true);
        try testing.expectEqualSlices(u8, "OVUHPLLLLY", ic.base_jit.code.items);
        try testing.expectEqualSlices(Cell, &.{ layouts.tagFixnum(0), layout, m1, generic, methods, layouts.tagFixnum(0), entries }, ts.items(&ic.base_jit.literals));
        try testing.expectEqual(@as(u64, 1), f.vm.dispatch_stats.pic_tuple_count);
    }
    {
        // No entries yet: load, dispatch prologue, then straight to the miss handler.
        var ic = InlineCacheJit.init(f.vm, .tag, generic);
        ic.registerRoot();
        defer ic.deinit();
        try ic.emitInlineCache(2, generic, methods, layouts.false_object, false);
        try testing.expectEqualSlices(u8, "OTPLLLLZ", ic.base_jit.code.items);
        try testing.expectEqualSlices(Cell, &.{ layouts.tagFixnum(-2 * @sizeOf(Cell)), generic, methods, layouts.tagFixnum(2), layouts.false_object }, ts.items(&ic.base_jit.literals));
    }
    {
        // The class-0 shortcut only applies to slot 0 of a tag PIC.
        var ic = InlineCacheJit.init(f.vm, .tuple, generic);
        ic.registerRoot();
        defer ic.deinit();
        try ic.emitCheckAndJump(.tuple, 0, layouts.tagFixnum(0), m1);
        try ic.emitCheckAndJump(.tag, 2, layouts.tagFixnum(0), m1);
        try ic.emitCheckAndJump(.tag, 0, layouts.tagFixnum(0), m1);
        try testing.expectEqualSlices(u8, "KHKHH", ic.base_jit.code.items);
    }
}

test "addInlineCacheEntry grows, replaces and deduplicates" {
    var f: ts.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const k1 = layouts.tagFixnum(1);
    const k2 = f.array(&.{layouts.tagFixnum(0)});
    const m1 = f.word(layouts.false_object);
    const m2 = f.word(layouts.false_object);
    const m3 = f.word(layouts.false_object);

    const first = addInlineCacheEntry(f.vm, layouts.false_object, k1, m1) orelse return error.TestUnexpectedResult;
    try testing.expectEqualSlices(Cell, &.{ k1, m1 }, ts.arrayItems(first));

    const second = addInlineCacheEntry(f.vm, first, k2, m2) orelse return error.TestUnexpectedResult;
    try testing.expect(second != first);
    try testing.expectEqualSlices(Cell, &.{ k1, m1, k2, m2 }, ts.arrayItems(second));

    // Same class and method: nothing to do.
    try testing.expectEqual(@as(?Cell, null), addInlineCacheEntry(f.vm, second, k2, m2));
    // Same class, new method: updated in place.
    try testing.expectEqual(@as(?Cell, second), addInlineCacheEntry(f.vm, second, k1, m3));
    try testing.expectEqualSlices(Cell, &.{ k1, m3, k2, m2 }, ts.arrayItems(second));
}

test "determineInlineCacheType and megaCacheHashcode" {
    var f: ts.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const m = f.word(layouts.false_object);
    const layout = f.array(&.{layouts.tagFixnum(0)});

    try testing.expectEqual(PicType.tag, determineInlineCacheType(layouts.false_object));
    try testing.expectEqual(PicType.tag, determineInlineCacheType(f.array(&.{ layouts.tagFixnum(2), m })));
    try testing.expectEqual(PicType.tuple, determineInlineCacheType(f.array(&.{ layout, m })));
    try testing.expectEqual(PicType.tuple, determineInlineCacheType(f.array(&.{ layouts.tagFixnum(1), m, layout, m })));

    // Tag classes hash by their untagged value into even slots; distinct
    // classes beyond the mask collide.
    try testing.expectEqual(@as(Cell, 10), megaCacheHashcode(layouts.tagFixnum(5), 7));
    try testing.expectEqual(@as(Cell, 10), megaCacheHashcode(layouts.tagFixnum(13), 7));
    try testing.expectEqual(@as(Cell, 0), megaCacheHashcode(layouts.tagFixnum(8), 7));
    try testing.expectEqual(@as(Cell, 14), megaCacheHashcode(layouts.tagFixnum(7), 7));
    const slot = megaCacheHashcode(layout, 31);
    try testing.expect(slot % 2 == 0 and slot <= 62);
    try testing.expectEqual(((layouts.UNTAG(layout) >> layouts.tag_bits) & 31) << 1, slot);
}

test "updatePicTransitions counts cold, monomorphic and megamorphic transitions" {
    var f: ts.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const stats = &f.vm.dispatch_stats;
    updatePicTransitions(f.vm, 0);
    updatePicTransitions(f.vm, 1);
    updatePicTransitions(f.vm, 2);
    updatePicTransitions(f.vm, f.vm.max_pic_size);
    try testing.expectEqual(@as(u64, 1), stats.cold_call_to_ic_transitions);
    try testing.expectEqual(@as(u64, 1), stats.ic_to_pic_transitions);
    try testing.expectEqual(@as(u64, 1), stats.pic_to_mega_transitions);
}

test "call site patcher rejects invalid sites and handles backward targets" {
    switch (builtin.cpu.arch) {
        .x86, .x86_64 => {
            var buf = [_]u8{0x90} ** 64;
            // Not a call or jump: no target.
            const bogus = @intFromPtr(&buf[5]);
            try testing.expect(!CallSitePatcher.isValidCallSite(bogus));
            try testing.expectEqual(@as(Cell, 0), CallSitePatcher.getCallTarget(bogus));

            // A call at offset 32 patched to point at the buffer start.
            buf[32] = 0xE8;
            const ra = @intFromPtr(&buf[37]);
            CallSitePatcher.setCallTarget(ra, @intFromPtr(&buf[0]));
            try testing.expectEqual(@as(i32, -37), std.mem.readInt(i32, buf[33..37], .little));
            try testing.expectEqual(@intFromPtr(&buf[0]), CallSitePatcher.getCallTarget(ra));
            try testing.expectEqual(@intFromPtr(&buf[0]), CallSitePatcher.getCallTargetUnchecked(ra));
            try testing.expect(!CallSitePatcher.isTailCallSite(ra));
            buf[32] = 0xE9;
            try testing.expect(CallSitePatcher.isTailCallSite(ra));
            try testing.expectEqual(@intFromPtr(&buf[0]), CallSitePatcher.getCallTarget(ra));
        },
        .aarch64 => {
            var buf align(4) = [_]u8{0} ** 64;
            const bogus = @intFromPtr(&buf[4]);
            try testing.expect(!CallSitePatcher.isValidCallSite(bogus));
            try testing.expectEqual(@as(Cell, 0), CallSitePatcher.getCallTarget(bogus));

            std.mem.writeInt(u32, buf[32..36], 0x94000000, .little);
            const ra = @intFromPtr(&buf[36]);
            CallSitePatcher.setCallTarget(ra, @intFromPtr(&buf[0]));
            try testing.expectEqual(@as(u32, 0x94000000 | (0x03ffffff & @as(u32, @bitCast(@as(i32, -8))))), std.mem.readInt(u32, buf[32..36], .little));
            try testing.expectEqual(@intFromPtr(&buf[0]), CallSitePatcher.getCallTarget(ra));
            try testing.expect(!CallSitePatcher.isTailCallSite(ra));
        },
        else => return error.SkipZigTest,
    }
}

test "inlineCacheMiss builds a PIC, patches the call site and counts transitions" {
    var f: ts.Fixture = undefined;
    try f.init();
    defer f.deinit();
    installPicMarkers(&f);

    const generic = f.word(layouts.false_object);
    const method = f.word(layouts.false_object);
    // Methods are indexed by type tag; the object is a fixnum (tag 0).
    var slots: [layouts.type_count]Cell = @splat(layouts.false_object);
    slots[0] = method;
    const methods = f.array(&slots);
    const obj = layouts.tagFixnum(5);
    const ra = try f.callSite();
    const site_target = CallSitePatcher.getCallTarget(ra);
    const base = f.vm.vm_asm.ctx.datastack;

    // The miss handler pushes generic, methods, index and cache entries; the
    // dispatched object sits below them at `index` cells from the top.
    f.vm.push(obj);
    f.vm.push(generic);
    f.vm.push(methods);
    f.vm.push(layouts.tagFixnum(0));
    f.vm.push(layouts.false_object);
    const xt = inlineCacheMiss(f.vm, ra);

    try testing.expect(xt != 0);
    try testing.expect(f.inCodeHeap(xt));
    const pic: *code_blocks.CodeBlock = @ptrFromInt(xt - @sizeOf(code_blocks.CodeBlock));
    try testing.expect(pic.isPic());
    try testing.expectEqual(generic, pic.owner);
    try testing.expect(!f.code_heap.isBlockUninitialized(pic));
    // One entry for class 0 in slot 0: no check, just the hit, then the miss path.
    try testing.expectEqualSlices(u8, "OTHPLLLLZ", pic.codeStart()[0..9]);
    try testing.expect(site_target != xt);
    try testing.expectEqual(xt, CallSitePatcher.getCallTarget(ra));
    try testing.expectEqual(@as(u64, 1), f.vm.dispatch_stats.cold_call_to_ic_transitions);
    try testing.expectEqual(@as(u64, 1), f.vm.dispatch_stats.pic_tag_count);
    try testing.expectEqual(obj, f.vm.pop());
    try testing.expectEqual(base, f.vm.vm_asm.ctx.datastack);
    try testing.expectEqual(@as(usize, 0), f.vm.code_roots.items.len);

    // A full cache goes megamorphic: fall back to the generic word's entry
    // point (0 here) and leave the call site alone.
    const full = f.array(&.{ layouts.tagFixnum(1), method, layouts.tagFixnum(2), method, layouts.tagFixnum(3), method });
    f.vm.push(obj);
    f.vm.push(generic);
    f.vm.push(methods);
    f.vm.push(layouts.tagFixnum(0));
    f.vm.push(full);
    try testing.expectEqual(@as(Cell, 0), inlineCacheMiss(f.vm, ra));
    try testing.expectEqual(xt, CallSitePatcher.getCallTarget(ra));
    try testing.expectEqual(@as(u64, 1), f.vm.dispatch_stats.pic_to_mega_transitions);
    try testing.expectEqual(obj, f.vm.pop());
}
