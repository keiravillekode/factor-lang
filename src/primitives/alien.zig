const std = @import("std");

const bignum = @import("../bignum.zig");
const code_blocks = @import("../code_blocks.zig");
const float_mod = @import("../float.zig");
const layouts = @import("../layouts.zig");
const math_mod = @import("../fixnum.zig");
const vm_mod = @import("../vm.zig");

const Cell = layouts.Cell;
const Fixnum = layouts.Fixnum;
const FactorVM = vm_mod.FactorVM;
const VMAssemblyFields = vm_mod.VMAssemblyFields;

fn toFixnum(vm: *FactorVM, tagged: Cell) Fixnum {
    const tag = layouts.typeTag(tagged);
    switch (tag) {
        .fixnum => {
            return layouts.untagFixnum(tagged);
        },
        .bignum => {
            const bn: *const bignum.Bignum = @ptrFromInt(layouts.UNTAG(tagged));
            return bignum.toFixnum(bn);
        },
        else => vm.typeError(.fixnum, tagged),
    }
}

pub var null_dll: ?*anyopaque = null;

pub fn initFfi() void {
    var rtld_mode: std.c.RTLD = .{};
    rtld_mode.LAZY = true;

    // Pre-load libm so dlsym(NULL, "pow") etc. work at runtime.
    // Zig statically resolves math builtins, so libm isn't in NEEDED — load it explicitly.
    var global_mode = rtld_mode;
    global_mode.GLOBAL = true;
    _ = std.c.dlopen("libm.so.6", global_mode);

    null_dll = std.c.dlopen(null, rtld_mode);
}

// --- Alien/FFI Primitives ---

// Get a pinned alien's address (alien with base == f)
fn pinnedAlienOffset(vm: *FactorVM, obj: Cell) ?[*]u8 {
    switch (@as(layouts.TypeTag, @enumFromInt(layouts.TAG(obj)))) {
        .alien => {
            const alien: *const layouts.Alien = @ptrFromInt(layouts.UNTAG(obj));
            if (alien.expired != layouts.false_object) {
                vm.expiredError(obj);
            }
            if (alien.base != layouts.false_object) {
                vm.typeError(.alien, obj);
            }
            return @ptrFromInt(alien.address);
        },
        .f => return null,
        else => {
            vm.typeError(.alien, obj);
        },
    }
}

pub export fn primitive_alien_address(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    const obj = vm.peek();
    switch (@as(layouts.TypeTag, @enumFromInt(layouts.TAG(obj)))) {
        .alien => {
            const alien: *const layouts.Alien = @ptrFromInt(layouts.UNTAG(obj));
            if (alien.expired != layouts.false_object) {
                vm.expiredError(obj);
            }
            if (alien.base != layouts.false_object) {
                // A non-pinned (displaced) alien has no stable address.
                // Matches C++ pinned_alien_offset: type_error(ALIEN_TYPE, obj).
                vm.typeError(.alien, obj);
            }
            vm.replace(math_mod.fromUnsignedCell(vm, alien.address));
        },
        .f => {
            vm.replace(layouts.tagFixnum(0));
        },
        else => {
            vm.typeError(.alien, obj);
        },
    }
}

pub export fn primitive_displaced_alien(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    // ( displacement alien -- displaced-alien )
    const alien = vm.pop();
    const displacement_cell = vm.pop();

    // Displacement may be a fixnum or a bignum (C++ uses to_cell). The old
    // fixnum-only path silently dropped bignum displacements to 0.
    const displacement: Cell = math_mod.toUnsignedCell(vm, displacement_cell);

    // Validate alien type - must be byte_array, alien, or f (false)
    const tag = layouts.typeTag(alien);
    if (tag != .byte_array and
        tag != .alien and
        alien != layouts.false_object)
    {
        vm.typeError(.alien, alien);
    }

    // If displacement is 0, return original
    if (displacement == 0) {
        vm.push(alien);
        return;
    }

    // Root the alien before potential GC from allocation
    var rooted_alien = alien;
    vm.data_roots.appendAssumeCapacity(&rooted_alien);
    defer _ = vm.data_roots.pop();

    const tagged = vm.allotObject(.alien, @sizeOf(layouts.Alien)) orelse
        vm.memoryError();
    const new_alien: *layouts.Alien = @ptrFromInt(layouts.UNTAG(tagged));
    new_alien.expired = layouts.false_object;

    // Use rooted_alien which may have been updated by GC
    if (layouts.hasTag(rooted_alien, .alien)) {
        const src_alien: *const layouts.Alien = @ptrFromInt(layouts.UNTAG(rooted_alien));
        new_alien.base = src_alien.base;
        new_alien.displacement = src_alien.displacement + displacement;
    } else {
        new_alien.base = rooted_alien;
        new_alien.displacement = displacement;
    }

    new_alien.updateAddress();
    vm.push(tagged);
}

// Helper to pop alien pointer with offset
// Stack effect: ( alien offset -- )
// Returns a valid pointer or raises a Factor-level memory error (never returns null).
inline fn alienPointer(vm: *FactorVM) [*]u8 {
    const offset_cell = vm.pop();
    const offset: Fixnum = if (layouts.hasTag(offset_cell, .fixnum))
        @bitCast(layouts.untagFixnumFast(offset_cell))
    else
        @call(.never_inline, toFixnum, .{ vm, offset_cell });
    const obj = vm.pop();
    if (vm.alienOffset(obj)) |ptr| {
        const addr = @intFromPtr(ptr) +% @as(usize, @bitCast(offset));
        return @ptrFromInt(addr);
    }
    vm.generalError(.memory, layouts.tagFixnum(0), layouts.false_object);
}

pub export fn primitive_alien_signed_1(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    const ptr = alienPointer(vm);
    const typed_ptr: *const i8 = @ptrCast(@alignCast(ptr));
    vm.push(layouts.tagFixnum(@intCast(typed_ptr.*)));
}

pub export fn primitive_set_alien_signed_1(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    const ptr = alienPointer(vm);
    const value_cell = vm.pop();
    const value: Fixnum = if (layouts.hasTag(value_cell, .fixnum))
        layouts.untagFixnum(value_cell)
    else
        @call(.never_inline, toFixnum, .{ vm, value_cell });
    const typed_ptr: *i8 = @ptrCast(ptr);
    typed_ptr.* = @truncate(value);
}

pub export fn primitive_alien_signed_2(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    const ptr = alienPointer(vm);
    const typed_ptr: *align(1) const i16 = @ptrCast(ptr);
    vm.push(layouts.tagFixnum(@intCast(typed_ptr.*)));
}

pub export fn primitive_set_alien_signed_2(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    const ptr = alienPointer(vm);
    const value_cell = vm.pop();
    const typed_ptr: *align(1) i16 = @ptrCast(ptr);
    typed_ptr.* = @truncate(toFixnum(vm, value_cell));
}

pub export fn primitive_alien_signed_4(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    const ptr = alienPointer(vm);
    const typed_ptr: *align(1) const i32 = @ptrCast(ptr);
    vm.push(layouts.tagFixnum(@intCast(typed_ptr.*)));
}

pub export fn primitive_set_alien_signed_4(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    const ptr = alienPointer(vm);
    const value_cell = vm.pop();
    const typed_ptr: *align(1) i32 = @ptrCast(ptr);
    typed_ptr.* = @truncate(toFixnum(vm, value_cell));
}

pub export fn primitive_alien_signed_8(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    const ptr = alienPointer(vm);
    const typed_ptr: *align(1) const i64 = @ptrCast(ptr);
    vm.push(math_mod.fromSignedCell(vm, typed_ptr.*));
}

pub export fn primitive_set_alien_signed_8(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    const ptr = alienPointer(vm);
    const value_cell = vm.pop();
    const typed_ptr: *align(1) i64 = @ptrCast(ptr);
    typed_ptr.* = @intCast(toFixnum(vm, value_cell));
}

pub export fn primitive_alien_unsigned_1(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    const ptr = alienPointer(vm);
    const typed_ptr: *const u8 = @ptrCast(@alignCast(ptr));
    vm.push(layouts.tagFixnum(@intCast(typed_ptr.*)));
}

pub export fn primitive_set_alien_unsigned_1(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    const ptr = alienPointer(vm);
    const value_cell = vm.pop();
    const value: Fixnum = if (layouts.hasTag(value_cell, .fixnum))
        layouts.untagFixnum(value_cell)
    else
        @call(.never_inline, toFixnum, .{ vm, value_cell });
    const typed_ptr: *u8 = @ptrCast(ptr);
    typed_ptr.* = @truncate(@as(u64, @bitCast(value)));
}

pub export fn primitive_alien_unsigned_2(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    const ptr = alienPointer(vm);
    const typed_ptr: *align(1) const u16 = @ptrCast(ptr);
    vm.push(layouts.tagFixnum(@intCast(typed_ptr.*)));
}

pub export fn primitive_set_alien_unsigned_2(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    const ptr = alienPointer(vm);
    const value_cell = vm.pop();
    const typed_ptr: *align(1) u16 = @ptrCast(ptr);
    typed_ptr.* = @truncate(@as(u64, @bitCast(toFixnum(vm, value_cell))));
}

pub export fn primitive_alien_unsigned_4(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    const ptr = alienPointer(vm);
    const typed_ptr: *align(1) const u32 = @ptrCast(ptr);
    vm.push(layouts.tagFixnum(@intCast(typed_ptr.*)));
}

pub export fn primitive_set_alien_unsigned_4(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    const ptr = alienPointer(vm);
    const value_cell = vm.pop();
    const typed_ptr: *align(1) u32 = @ptrCast(ptr);
    typed_ptr.* = @truncate(@as(u64, @bitCast(toFixnum(vm, value_cell))));
}

pub export fn primitive_alien_unsigned_8(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    const ptr = alienPointer(vm);
    const typed_ptr: *align(1) const u64 = @ptrCast(ptr);
    vm.push(math_mod.fromUnsignedCell(vm, typed_ptr.*));
}

pub export fn primitive_set_alien_unsigned_8(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    const ptr = alienPointer(vm);
    const value_cell = vm.pop();
    const typed_ptr: *align(1) u64 = @ptrCast(ptr);
    typed_ptr.* = @bitCast(toFixnum(vm, value_cell));
}

pub export fn primitive_alien_float(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    const ptr = alienPointer(vm);
    const typed_ptr: *align(1) const f32 = @ptrCast(ptr);
    const boxed = float_mod.allocBoxedFloat(vm, @floatCast(typed_ptr.*)) catch
        vm.memoryError();
    vm.push(@intFromPtr(boxed) | @intFromEnum(layouts.TypeTag.float));
}

pub export fn primitive_set_alien_float(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    const ptr = alienPointer(vm);
    const value_cell = vm.pop();
    const typed_ptr: *align(1) f32 = @ptrCast(ptr);
    if (layouts.hasTag(value_cell, .float)) {
        const boxed: *const layouts.BoxedFloat = @ptrFromInt(layouts.UNTAG(value_cell));
        typed_ptr.* = @floatCast(boxed.n);
    }
}

pub export fn primitive_alien_double(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    const ptr = alienPointer(vm);
    const typed_ptr: *align(1) const f64 = @ptrCast(ptr);
    const boxed = float_mod.allocBoxedFloat(vm, typed_ptr.*) catch
        vm.memoryError();
    vm.push(@intFromPtr(boxed) | @intFromEnum(layouts.TypeTag.float));
}

pub export fn primitive_set_alien_double(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    const ptr = alienPointer(vm);
    const value_cell = vm.pop();
    const typed_ptr: *align(1) f64 = @ptrCast(ptr);
    if (layouts.hasTag(value_cell, .float)) {
        const boxed: *const layouts.BoxedFloat = @ptrFromInt(layouts.UNTAG(value_cell));
        typed_ptr.* = boxed.n;
    }
}

pub export fn primitive_alien_cell(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    const ptr = alienPointer(vm);
    const typed_ptr: *align(1) const Cell = @ptrCast(ptr);
    const value = typed_ptr.*;

    if (value == 0) {
        vm.push(layouts.false_object);
        return;
    }

    const tagged = vm.allotObject(.alien, @sizeOf(layouts.Alien)) orelse
        vm.memoryError();
    const alien: *layouts.Alien = @ptrFromInt(layouts.UNTAG(tagged));
    alien.base = layouts.false_object;
    alien.expired = layouts.false_object;
    alien.displacement = value;
    alien.address = value;
    vm.push(tagged);
}

pub export fn primitive_set_alien_cell(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    const ptr = alienPointer(vm);
    const value_cell = vm.pop();
    const typed_ptr: *align(1) Cell = @ptrCast(ptr);
    if (pinnedAlienOffset(vm, value_cell)) |alien_ptr| {
        typed_ptr.* = @intFromPtr(alien_ptr);
    } else {
        typed_ptr.* = 0;
    }
}

// Signed/unsigned cell primitives — read/write cell-sized integers (not alien pointers).
pub const primitive_alien_signed_cell = primitive_alien_signed_8;
pub const primitive_set_alien_signed_cell = primitive_set_alien_signed_8;
pub const primitive_alien_unsigned_cell = primitive_alien_unsigned_8;
pub const primitive_set_alien_unsigned_cell = primitive_set_alien_unsigned_8;

comptime {
    @export(&primitive_alien_signed_8, .{ .name = "primitive_alien_signed_cell", .linkage = .strong });
    @export(&primitive_set_alien_signed_8, .{ .name = "primitive_set_alien_signed_cell", .linkage = .strong });
    @export(&primitive_alien_unsigned_8, .{ .name = "primitive_alien_unsigned_cell", .linkage = .strong });
    @export(&primitive_set_alien_unsigned_8, .{ .name = "primitive_set_alien_unsigned_cell", .linkage = .strong });
}

pub export fn primitive_dlopen(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    const path_cell = vm.pop();

    vm.checkTag(path_cell, .byte_array);

    const path_ba: *const layouts.ByteArray = @ptrFromInt(layouts.UNTAG(path_cell));
    const capacity = layouts.untagFixnumUnsigned(path_ba.capacity);
    const path_data = path_ba.data();

    var path_buf: [1024]u8 = undefined;
    if (capacity >= path_buf.len) {
        vm.push(layouts.false_object);
        return;
    }
    @memcpy(path_buf[0..capacity], path_data[0..capacity]);
    path_buf[capacity] = 0;

    var rtld_mode: std.c.RTLD = .{};
    rtld_mode.LAZY = true;
    rtld_mode.GLOBAL = true;
    const handle = std.c.dlopen(@ptrCast(&path_buf), rtld_mode);

    // A newly opened RTLD_GLOBAL library can change what a symbol resolves to.
    if (handle != null) code_blocks.clearDlsymCache();

    // Root the path byte-array across the dll allocation: allotObject can GC and
    // move it, and it is no longer referenced from the data stack after the pop
    // above, so storing the pre-allocation pointer would dangle (matches the C++
    // data_root<byte_array> path in vm/alien.cpp).
    var rooted_path = path_cell;
    std.debug.assert(vm.data_roots.items.len < vm.data_roots.capacity);
    vm.data_roots.appendAssumeCapacity(&rooted_path);
    defer _ = vm.data_roots.pop();

    const tagged = vm.allotObject(.dll, @sizeOf(layouts.Dll)) orelse {
        if (handle) |h| _ = std.c.dlclose(h);
        vm.memoryError();
    };
    const dll: *layouts.Dll = @ptrFromInt(layouts.UNTAG(tagged));
    dll.path = rooted_path;
    dll.handle = handle;
    vm.push(tagged);
}

pub export fn primitive_dlsym(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    const library_cell = vm.pop();
    const name_cell = vm.peek();

    vm.checkTag(name_cell, .byte_array);

    const name_ba: *const layouts.ByteArray = @ptrFromInt(layouts.UNTAG(name_cell));
    const name_len = layouts.untagFixnumUnsigned(name_ba.capacity);
    const name_data = name_ba.data();

    var name_buf: [256]u8 = undefined;
    if (name_len >= name_buf.len) {
        vm.replace(layouts.false_object);
        return;
    }
    @memcpy(name_buf[0..name_len], name_data[0..name_len]);
    name_buf[name_len] = 0;

    const sym_addr: ?*anyopaque = blk: {
        if (library_cell == layouts.false_object) {
            break :blk std.c.dlsym(null_dll, @ptrCast(&name_buf));
        }
        vm.checkTag(library_cell, .dll);
        const dll: *const layouts.Dll = @ptrFromInt(layouts.UNTAG(library_cell));
        if (dll.handle == null) break :blk null;
        break :blk std.c.dlsym(dll.handle, @ptrCast(&name_buf));
    };

    if (sym_addr) |addr| {
        const tagged = vm.allotObject(.alien, @sizeOf(layouts.Alien)) orelse
            vm.memoryError();
        const alien: *layouts.Alien = @ptrFromInt(layouts.UNTAG(tagged));
        alien.base = layouts.false_object;
        alien.expired = layouts.false_object;
        const addr_val = @intFromPtr(addr);
        alien.displacement = addr_val;
        alien.address = addr_val;
        vm.replace(tagged);
    } else {
        vm.replace(layouts.false_object);
    }
}

pub export fn primitive_dlclose(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    const dll_cell = vm.pop();

    vm.checkTag(dll_cell, .dll);

    const dll: *layouts.Dll = @ptrFromInt(layouts.UNTAG(dll_cell));
    if (dll.handle) |handle| {
        _ = std.c.dlclose(handle);
        dll.handle = null;
        // Cached addresses into the closed library are now dangling.
        code_blocks.clearDlsymCache();
    }
}

pub export fn primitive_dll_validp(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    const library = vm.peek();

    const objects = @import("../objects.zig");
    const canonical_true = vm.vm_asm.special_objects[@intFromEnum(objects.SpecialObject.canonical_true)];

    if (library == layouts.false_object) {
        vm.replace(canonical_true);
        return;
    }

    vm.checkTag(library, .dll);

    const dll: *const layouts.Dll = @ptrFromInt(layouts.UNTAG(library));
    vm.replace(if (dll.handle != null) canonical_true else layouts.false_object);
}

pub export fn primitive_current_callback(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    if (vm.callback_ids.items.len > 0) {
        vm.push(layouts.tagFixnum(vm.callback_ids.items[vm.callback_ids.items.len - 1]));
    } else {
        vm.push(layouts.tagFixnum(0));
    }
}

pub export fn primitive_callback(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    // ( word return-rewind -- alien )
    const return_rewind_cell = vm.pop();
    const word_cell = vm.pop();

    const return_rewind: Cell = layouts.untagFixnumUnsigned(return_rewind_cell);

    const callback_heap = vm.callbacks orelse {
        vm.generalError(.callback_space_overflow, layouts.false_object, layouts.false_object);
    };

    const vm_ptr: Cell = @intFromPtr(&vm.vm_asm);

    const stub = callback_heap.add(word_cell, return_rewind, vm_ptr, vm) orelse {
        vm.generalError(.callback_space_overflow, layouts.false_object, layouts.false_object);
    };

    const func = stub.entryPoint();

    const tagged = vm.allotObject(.alien, @sizeOf(layouts.Alien)) orelse
        vm.memoryError();
    const alien: *layouts.Alien = @ptrFromInt(layouts.UNTAG(tagged));
    alien.base = layouts.false_object;
    alien.expired = layouts.false_object;
    alien.displacement = func;
    alien.address = func;
    vm.push(tagged);
}

pub export fn primitive_free_callback(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    const alien_cell = vm.pop();

    if (vm.alienOffset(alien_cell)) |entry_point| {
        const entry_addr: usize = @intFromPtr(entry_point);
        const code_block_addr = entry_addr - @sizeOf(code_blocks.CodeBlock);
        const stub: *code_blocks.CodeBlock = @ptrFromInt(code_block_addr);

        if (vm.callbacks) |callback_heap| {
            callback_heap.free(stub);
        }
    }
}

// --- Tests ---

const testing = std.testing;

const AlienTestVM = struct {
    vm: *FactorVM,
    heap: *@import("../data_heap.zig").DataHeap,
    stack_base: Cell,
    true_obj: Cell,

    fn init() !AlienTestVM {
        const data_heap_mod = @import("../data_heap.zig");
        const objects = @import("../objects.zig");
        const allocator = testing.allocator;
        const vm = try FactorVM.init(allocator);
        vm.vm_asm.ctx = try vm.newContext();
        vm.vm_asm.spare_ctx = try vm.newContext();
        // vm.gc stays null, so the nursery must hold every allocation of a test.
        const heap = try data_heap_mod.DataHeap.init(allocator, 256 * 1024, 64 * 1024, 64 * 1024);
        vm.setDataHeap(heap);
        // canonical_true is f in a bare VM; install a sentinel so t and f differ.
        const true_obj = layouts.tagFixnum(0x7472_7565);
        vm.vm_asm.special_objects[@intFromEnum(objects.SpecialObject.canonical_true)] = true_obj;
        return .{
            .vm = vm,
            .heap = heap,
            .stack_base = vm.vm_asm.ctx.datastack,
            .true_obj = true_obj,
        };
    }

    fn deinit(self: *AlienTestVM) void {
        self.heap.deinit();
        self.vm.cards_array = null;
        self.vm.decks_array = null;
        self.vm.deinit();
    }

    fn fields(self: *AlienTestVM) *VMAssemblyFields {
        return &self.vm.vm_asm;
    }

    fn push(self: *AlienTestVM, cell: Cell) void {
        self.vm.push(cell);
    }

    fn pushFixnum(self: *AlienTestVM, n: Fixnum) void {
        self.vm.push(layouts.tagFixnum(n));
    }

    fn pop(self: *AlienTestVM) Cell {
        return self.vm.pop();
    }

    fn popFixnum(self: *AlienTestVM) !Fixnum {
        const cell = self.vm.pop();
        try testing.expect(layouts.hasTag(cell, .fixnum));
        return layouts.untagFixnum(cell);
    }

    fn popAlien(self: *AlienTestVM) !*layouts.Alien {
        return alienFrom(self.vm.pop());
    }

    fn byteArray(self: *AlienTestVM, bytes: []const u8) Cell {
        const tagged = self.vm.allotByteArray(bytes.len);
        const ba: *layouts.ByteArray = @ptrFromInt(layouts.UNTAG(tagged));
        @memcpy(ba.data()[0..bytes.len], bytes);
        return tagged;
    }

    // ( obj offset -- value )
    fn read(self: *AlienTestVM, prim: *const fn (*VMAssemblyFields) callconv(.c) void, obj: Cell, offset: Fixnum) Cell {
        self.push(obj);
        self.pushFixnum(offset);
        prim(self.fields());
        return self.pop();
    }

    // ( value obj offset -- )
    fn write(self: *AlienTestVM, prim: *const fn (*VMAssemblyFields) callconv(.c) void, obj: Cell, offset: Fixnum, value: Cell) void {
        self.push(value);
        self.push(obj);
        self.pushFixnum(offset);
        prim(self.fields());
    }

    fn expectStackBalanced(self: *AlienTestVM) !void {
        try testing.expectEqual(self.stack_base, self.vm.vm_asm.ctx.datastack);
    }
};

fn alienFrom(cell: Cell) !*layouts.Alien {
    try testing.expect(layouts.hasTag(cell, .alien));
    return @ptrFromInt(layouts.UNTAG(cell));
}

fn byteArrayData(tagged: Cell) [*]u8 {
    const ba: *layouts.ByteArray = @ptrFromInt(layouts.UNTAG(tagged));
    return ba.data();
}

fn bignumCell(cell: Cell) !Cell {
    try testing.expect(layouts.hasTag(cell, .bignum));
    const bn: *const bignum.Bignum = @ptrFromInt(layouts.UNTAG(cell));
    return bignum.toCell(bn);
}

fn bignumInt64(cell: Cell) !i64 {
    try testing.expect(layouts.hasTag(cell, .bignum));
    const bn: *const bignum.Bignum = @ptrFromInt(layouts.UNTAG(cell));
    return bignum.toInt64(bn);
}

test "displaced-alien over a byte array, an alien and a pinned address" {
    var t = try AlienTestVM.init();
    defer t.deinit();

    const ba = t.byteArray(&[_]u8{0} ** 16);
    const ba_data = @intFromPtr(byteArrayData(ba));

    // Displacement 0 hands back the original object untouched.
    t.pushFixnum(0);
    t.push(ba);
    primitive_displaced_alien(t.fields());
    try testing.expectEqual(ba, t.pop());

    // Over a byte array: base is the byte array, address points into its data.
    t.pushFixnum(4);
    t.push(ba);
    primitive_displaced_alien(t.fields());
    const a1_cell = t.vm.peek();
    const a1 = try t.popAlien();
    try testing.expectEqual(ba, a1.base);
    try testing.expectEqual(layouts.false_object, a1.expired);
    try testing.expectEqual(@as(Cell, 4), a1.displacement);
    try testing.expectEqual(ba_data + 4, a1.address);
    try testing.expectEqual(ba_data + 4, @intFromPtr(t.vm.alienOffset(a1_cell).?));

    // Over that alien: displacements accumulate, the base stays the byte array.
    t.pushFixnum(6);
    t.push(a1_cell);
    primitive_displaced_alien(t.fields());
    const a2 = try t.popAlien();
    try testing.expectEqual(ba, a2.base);
    try testing.expectEqual(@as(Cell, 10), a2.displacement);
    try testing.expectEqual(ba_data + 10, a2.address);

    // Over f (a raw address): base stays f and the address is the displacement.
    t.pushFixnum(0x1000);
    t.push(layouts.false_object);
    primitive_displaced_alien(t.fields());
    const raw_cell = t.vm.peek();
    const raw = try t.popAlien();
    try testing.expectEqual(layouts.false_object, raw.base);
    try testing.expectEqual(@as(Cell, 0x1000), raw.displacement);
    try testing.expectEqual(@as(Cell, 0x1000), raw.address);

    t.pushFixnum(0x10);
    t.push(raw_cell);
    primitive_displaced_alien(t.fields());
    const raw2 = try t.popAlien();
    try testing.expectEqual(layouts.false_object, raw2.base);
    try testing.expectEqual(@as(Cell, 0x1010), raw2.address);

    // A bignum displacement is honoured (it used to be dropped to 0).
    const big = try bignum.fromUint64(t.vm, @as(u64, 1) << 62);
    t.push(layouts.tagBignum(big));
    t.push(layouts.false_object);
    primitive_displaced_alien(t.fields());
    const big_alien = try t.popAlien();
    try testing.expectEqual(@as(Cell, 1) << 62, big_alien.address);

    try t.expectStackBalanced();
}

test "alien-address of pinned aliens and f" {
    var t = try AlienTestVM.init();
    defer t.deinit();

    // f has address 0.
    t.push(layouts.false_object);
    primitive_alien_address(t.fields());
    try testing.expectEqual(@as(Fixnum, 0), try t.popFixnum());

    // A small address comes back as a fixnum.
    t.push(t.vm.allotAlien(layouts.false_object, 0x1234));
    primitive_alien_address(t.fields());
    try testing.expectEqual(@as(Fixnum, 0x1234), try t.popFixnum());

    // An address with the high bit set does not fit a fixnum.
    const high: Cell = 0xFFFF_FFFF_FFFF_FFF0;
    t.push(t.vm.allotAlien(layouts.false_object, high));
    primitive_alien_address(t.fields());
    try testing.expectEqual(high, try bignumCell(t.pop()));

    try t.expectStackBalanced();
}

test "alien integer accessors read every width with the right signedness" {
    var t = try AlienTestVM.init();
    defer t.deinit();

    const ba = t.byteArray(&[_]u8{
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80,
    });

    try testing.expectEqual(layouts.tagFixnum(-1), t.read(&primitive_alien_signed_1, ba, 0));
    try testing.expectEqual(layouts.tagFixnum(255), t.read(&primitive_alien_unsigned_1, ba, 0));
    try testing.expectEqual(layouts.tagFixnum(-1), t.read(&primitive_alien_signed_2, ba, 0));
    try testing.expectEqual(layouts.tagFixnum(65535), t.read(&primitive_alien_unsigned_2, ba, 0));
    try testing.expectEqual(layouts.tagFixnum(-1), t.read(&primitive_alien_signed_4, ba, 0));
    try testing.expectEqual(layouts.tagFixnum(4294967295), t.read(&primitive_alien_unsigned_4, ba, 0));
    try testing.expectEqual(layouts.tagFixnum(-1), t.read(&primitive_alien_signed_8, ba, 0));
    try testing.expectEqual(@as(Cell, std.math.maxInt(u64)), try bignumCell(t.read(&primitive_alien_unsigned_8, ba, 0)));

    // The second half holds 0x8000000000000000.
    try testing.expectEqual(@as(i64, std.math.minInt(i64)), try bignumInt64(t.read(&primitive_alien_signed_8, ba, 8)));
    try testing.expectEqual(@as(Cell, 1) << 63, try bignumCell(t.read(&primitive_alien_unsigned_8, ba, 8)));
    try testing.expectEqual(layouts.tagFixnum(0), t.read(&primitive_alien_signed_4, ba, 8));
    try testing.expectEqual(layouts.tagFixnum(std.math.minInt(i32)), t.read(&primitive_alien_signed_4, ba, 12));
    try testing.expectEqual(layouts.tagFixnum(1 << 31), t.read(&primitive_alien_unsigned_4, ba, 12));
    try testing.expectEqual(layouts.tagFixnum(std.math.minInt(i16)), t.read(&primitive_alien_signed_2, ba, 14));
    try testing.expectEqual(layouts.tagFixnum(1 << 15), t.read(&primitive_alien_unsigned_2, ba, 14));
    try testing.expectEqual(layouts.tagFixnum(-128), t.read(&primitive_alien_signed_1, ba, 15));
    try testing.expectEqual(layouts.tagFixnum(128), t.read(&primitive_alien_unsigned_1, ba, 15));

    // The signed/unsigned cell primitives are the 8-byte ones.
    try testing.expectEqual(&primitive_alien_signed_8, &primitive_alien_signed_cell);
    try testing.expectEqual(&primitive_alien_unsigned_8, &primitive_alien_unsigned_cell);

    // Through a displaced alien the offset is added to the alien's address.
    t.pushFixnum(8);
    t.push(ba);
    primitive_displaced_alien(t.fields());
    const displaced = t.pop();
    try testing.expectEqual(layouts.tagFixnum(128), t.read(&primitive_alien_unsigned_1, displaced, 7));
    try testing.expectEqual(layouts.tagFixnum(255), t.read(&primitive_alien_unsigned_1, displaced, -1));

    try t.expectStackBalanced();
}

test "alien integer setters truncate fixnums and accept bignums" {
    var t = try AlienTestVM.init();
    defer t.deinit();

    const ba = t.byteArray(&[_]u8{0} ** 16);
    const data = byteArrayData(ba);

    t.write(&primitive_set_alien_unsigned_1, ba, 3, layouts.tagFixnum(0x1FF));
    try testing.expectEqual(@as(u8, 0xFF), data[3]);
    t.write(&primitive_set_alien_signed_1, ba, 4, layouts.tagFixnum(-2));
    try testing.expectEqual(@as(u8, 0xFE), data[4]);
    t.write(&primitive_set_alien_signed_2, ba, 6, layouts.tagFixnum(-2));
    try testing.expectEqualSlices(u8, &[_]u8{ 0xFE, 0xFF }, data[6..8]);
    t.write(&primitive_set_alien_unsigned_2, ba, 6, layouts.tagFixnum(0x1_ABCD));
    try testing.expectEqualSlices(u8, &[_]u8{ 0xCD, 0xAB }, data[6..8]);
    t.write(&primitive_set_alien_unsigned_4, ba, 8, layouts.tagFixnum(0xDEADBEEF));
    try testing.expectEqualSlices(u8, &[_]u8{ 0xEF, 0xBE, 0xAD, 0xDE }, data[8..12]);
    t.write(&primitive_set_alien_signed_4, ba, 12, layouts.tagFixnum(-1));
    try testing.expectEqualSlices(u8, &[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF }, data[12..16]);

    // 8-byte stores take fixnums and bignums alike.
    t.write(&primitive_set_alien_signed_8, ba, 0, layouts.tagFixnum(1));
    try testing.expectEqualSlices(u8, &[_]u8{ 1, 0, 0, 0, 0, 0, 0, 0 }, data[0..8]);
    const neg = try bignum.fromInt64(t.vm, -(@as(i64, 1) << 62));
    t.write(&primitive_set_alien_signed_8, ba, 0, layouts.tagBignum(neg));
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0xC0 }, data[0..8]);
    const all_ones = try bignum.fromUint64(t.vm, std.math.maxInt(u64));
    t.write(&primitive_set_alien_unsigned_8, ba, 8, layouts.tagBignum(all_ones));
    try testing.expectEqualSlices(u8, &[_]u8{0xFF} ** 8, data[8..16]);
    @memset(data[8..16], 0);
    t.write(&primitive_set_alien_unsigned_8, ba, 8, layouts.tagFixnum(-1));
    try testing.expectEqualSlices(u8, &[_]u8{0xFF} ** 8, data[8..16]);

    // Round trips through the matching reader.
    try testing.expectEqual(@as(i64, -(@as(i64, 1) << 62)), try bignumInt64(t.read(&primitive_alien_signed_8, ba, 0)));
    try testing.expectEqual(layouts.tagFixnum(-1), t.read(&primitive_alien_signed_8, ba, 8));

    try t.expectStackBalanced();
}

test "alien float and double accessors" {
    var t = try AlienTestVM.init();
    defer t.deinit();

    const ba = t.byteArray(&[_]u8{0} ** 16);
    const data = byteArrayData(ba);

    const boxed = try float_mod.allocBoxedFloat(t.vm, 1.5);
    t.write(&primitive_set_alien_float, ba, 0, layouts.tagFloat(boxed));
    try testing.expectEqual(@as(u32, 0x3FC00000), std.mem.readInt(u32, data[0..4], .little));
    t.write(&primitive_set_alien_double, ba, 8, layouts.tagFloat(boxed));
    try testing.expectEqual(@as(u64, 0x3FF8000000000000), std.mem.readInt(u64, data[8..16], .little));

    const f = t.read(&primitive_alien_float, ba, 0);
    try testing.expect(layouts.hasTag(f, .float));
    try testing.expectEqual(@as(f64, 1.5), float_mod.untagFloat(f));
    const d = t.read(&primitive_alien_double, ba, 8);
    try testing.expect(layouts.hasTag(d, .float));
    try testing.expectEqual(@as(f64, 1.5), float_mod.untagFloat(d));

    // A float32 read widens exactly; a non-float value is silently not stored.
    std.mem.writeInt(u32, data[4..8], 0x40490FDB, .little);
    const pi_f32: f32 = @bitCast(@as(u32, 0x40490FDB));
    try testing.expectEqual(@as(f64, pi_f32), float_mod.untagFloat(t.read(&primitive_alien_float, ba, 4)));
    t.write(&primitive_set_alien_float, ba, 4, layouts.tagFixnum(7));
    try testing.expectEqual(@as(u32, 0x40490FDB), std.mem.readInt(u32, data[4..8], .little));
    t.write(&primitive_set_alien_double, ba, 8, layouts.false_object);
    try testing.expectEqual(@as(u64, 0x3FF8000000000000), std.mem.readInt(u64, data[8..16], .little));

    try t.expectStackBalanced();
}

test "alien-cell reads and writes pointers as pinned aliens" {
    var t = try AlienTestVM.init();
    defer t.deinit();

    const ba = t.byteArray(&[_]u8{0} ** 16);
    const data = byteArrayData(ba);

    // A zero cell reads as f.
    try testing.expectEqual(layouts.false_object, t.read(&primitive_alien_cell, ba, 0));

    // Storing a pinned alien writes its address; f writes 0.
    const pinned = t.vm.allotAlien(layouts.false_object, 0xABCD_0000);
    t.write(&primitive_set_alien_cell, ba, 0, pinned);
    try testing.expectEqual(@as(u64, 0xABCD_0000), std.mem.readInt(u64, data[0..8], .little));

    const read_back = try alienFrom(t.read(&primitive_alien_cell, ba, 0));
    try testing.expectEqual(layouts.false_object, read_back.base);
    try testing.expectEqual(layouts.false_object, read_back.expired);
    try testing.expectEqual(@as(Cell, 0xABCD_0000), read_back.address);
    try testing.expectEqual(@as(Cell, 0xABCD_0000), read_back.displacement);

    t.write(&primitive_set_alien_cell, ba, 0, layouts.false_object);
    try testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, data[0..8], .little));

    try t.expectStackBalanced();
}

test "dlsym, dlopen, dlclose and dll-valid?" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var t = try AlienTestVM.init();
    defer t.deinit();

    // ( name library -- alien ): f means the global namespace.
    t.push(t.byteArray("strlen"));
    t.push(layouts.false_object);
    primitive_dlsym(t.fields());
    const strlen_alien = try t.popAlien();
    try testing.expectEqual(layouts.false_object, strlen_alien.base);
    const strlen_fn: *const fn ([*:0]const u8) callconv(.c) usize = @ptrFromInt(strlen_alien.address);
    try testing.expectEqual(@as(usize, 5), strlen_fn("hello"));

    t.push(t.byteArray("no_such_symbol_in_any_library"));
    t.push(layouts.false_object);
    primitive_dlsym(t.fields());
    try testing.expectEqual(layouts.false_object, t.pop());

    // f is always a valid library.
    t.push(layouts.false_object);
    primitive_dll_validp(t.fields());
    try testing.expectEqual(t.true_obj, t.pop());

    // A real library: valid, symbols resolve, and closing invalidates it.
    t.push(t.byteArray("libm.so.6"));
    primitive_dlopen(t.fields());
    const dll_cell = t.pop();
    try testing.expect(layouts.hasTag(dll_cell, .dll));
    const dll: *const layouts.Dll = @ptrFromInt(layouts.UNTAG(dll_cell));
    try testing.expect(dll.handle != null);
    try testing.expect(layouts.hasTag(dll.path, .byte_array));

    t.push(dll_cell);
    primitive_dll_validp(t.fields());
    try testing.expectEqual(t.true_obj, t.pop());

    t.push(t.byteArray("cos"));
    t.push(dll_cell);
    primitive_dlsym(t.fields());
    const cos_alien = try t.popAlien();
    const cos_fn: *const fn (f64) callconv(.c) f64 = @ptrFromInt(cos_alien.address);
    try testing.expectEqual(@as(f64, 1.0), cos_fn(0.0));

    t.push(dll_cell);
    primitive_dlclose(t.fields());
    try testing.expect(dll.handle == null);
    t.push(dll_cell);
    primitive_dll_validp(t.fields());
    try testing.expectEqual(layouts.false_object, t.pop());
    t.push(t.byteArray("cos"));
    t.push(dll_cell);
    primitive_dlsym(t.fields());
    try testing.expectEqual(layouts.false_object, t.pop());
    // Closing twice is harmless.
    t.push(dll_cell);
    primitive_dlclose(t.fields());

    // A missing library yields a dll object without a handle.
    t.push(t.byteArray("/nonexistent/libnothing.so"));
    primitive_dlopen(t.fields());
    const bad_cell = t.pop();
    const bad: *const layouts.Dll = @ptrFromInt(layouts.UNTAG(bad_cell));
    try testing.expect(bad.handle == null);
    t.push(bad_cell);
    primitive_dll_validp(t.fields());
    try testing.expectEqual(layouts.false_object, t.pop());

    // An over-long path is rejected up front.
    t.push(t.byteArray(&[_]u8{'a'} ** 1024));
    primitive_dlopen(t.fields());
    try testing.expectEqual(layouts.false_object, t.pop());

    try t.expectStackBalanced();
}

test "current-callback reports the innermost callback id" {
    var t = try AlienTestVM.init();
    defer t.deinit();

    primitive_current_callback(t.fields());
    try testing.expectEqual(@as(Fixnum, 0), try t.popFixnum());

    try t.vm.callback_ids.append(testing.allocator, 3);
    try t.vm.callback_ids.append(testing.allocator, 9);
    primitive_current_callback(t.fields());
    try testing.expectEqual(@as(Fixnum, 9), try t.popFixnum());
    _ = t.vm.callback_ids.pop();
    primitive_current_callback(t.fields());
    try testing.expectEqual(@as(Fixnum, 3), try t.popFixnum());

    try t.expectStackBalanced();
}

test "callback primitive fills a stub from the template and free-callback releases it" {
    const builtin = @import("builtin");
    if (builtin.cpu.arch != .x86_64) return error.SkipZigTest;

    const callbacks = @import("../callbacks.zig");
    const objects = @import("../objects.zig");

    var t = try AlienTestVM.init();
    defer t.deinit();

    var heap = try callbacks.CallbackHeap.init(testing.allocator, 64 * 1024);
    defer heap.deinit();
    t.vm.callbacks = &heap;

    // Template: 32 bytes of int3 with four absolute-cell operands at 8-byte
    // steps. On x86-64 the heap stores vm_ptr at operands 0 and 2, the word's
    // entry point at 1 and the return rewind at 3.
    const Entry = code_blocks.RelocationEntry;
    var reloc_bytes: [4 * @sizeOf(Entry)]u8 = undefined;
    const entries = [_]Entry{
        Entry.init(.vm, .absolute_cell, 8),
        Entry.init(.entry_point, .absolute_cell, 16),
        Entry.init(.vm, .absolute_cell, 24),
        Entry.init(.untagged, .absolute_cell, 32),
    };
    for (entries, 0..) |e, i| {
        std.mem.writeInt(u32, reloc_bytes[i * 4 ..][0..4], e.value, .little);
    }
    const reloc_ba = t.byteArray(&reloc_bytes);
    const insns_ba = t.byteArray(&[_]u8{0xCC} ** 32);
    const stub_array = t.vm.allotArray(2, layouts.false_object) orelse return error.OutOfMemory;
    const stub_arr: *layouts.Array = @ptrFromInt(layouts.UNTAG(stub_array));
    stub_arr.data()[0] = reloc_ba;
    stub_arr.data()[1] = insns_ba;
    t.vm.vm_asm.special_objects[@intFromEnum(objects.SpecialObject.callback_stub)] = stub_array;

    // The owner word supplies the entry point patched in by update().
    const word_cell = t.vm.allotObject(.word, @sizeOf(layouts.Word)) orelse return error.OutOfMemory;
    const word: *layouts.Word = @ptrFromInt(layouts.UNTAG(word_cell));
    word.hashcode_field = layouts.tagFixnum(0);
    word.name = layouts.false_object;
    word.vocabulary = layouts.false_object;
    word.def = layouts.false_object;
    word.props = layouts.false_object;
    word.pic_def = layouts.false_object;
    word.pic_tail_def = layouts.false_object;
    word.subprimitive = layouts.false_object;
    word.entry_point = 0x1122_3344_5566_7788;

    // ( word return-rewind -- alien )
    t.push(word_cell);
    t.pushFixnum(0x40);
    primitive_callback(t.fields());
    const cb_cell = t.vm.peek();
    const cb = try t.popAlien();
    try testing.expectEqual(layouts.false_object, cb.base);
    try testing.expect(heap.segment.?.contains(cb.address));

    const stub: *code_blocks.CodeBlock = @ptrFromInt(cb.address - @sizeOf(code_blocks.CodeBlock));
    try testing.expect(!stub.isFree());
    try testing.expectEqual(word_cell, stub.owner);
    try testing.expectEqual(@as(Cell, 32), stub.codeSize());
    const code: [*]const u8 = @ptrFromInt(cb.address);
    const vm_ptr: Cell = @intFromPtr(&t.vm.vm_asm);
    try testing.expectEqual(vm_ptr, std.mem.readInt(u64, code[0..8], .little));
    try testing.expectEqual(@as(u64, 0x1122_3344_5566_7788), std.mem.readInt(u64, code[8..16], .little));
    try testing.expectEqual(vm_ptr, std.mem.readInt(u64, code[16..24], .little));
    try testing.expectEqual(@as(u64, 0x40), std.mem.readInt(u64, code[24..32], .little));

    try testing.expectEqual(stub.size(), heap.room().occupied_space);

    // free-callback marks the stub free and returns its bytes to the heap.
    t.push(cb_cell);
    primitive_free_callback(t.fields());
    try testing.expect(stub.isFree());
    try testing.expectEqual(@as(Cell, 0), heap.room().occupied_space);

    // Without a template, no stub can be made.
    t.vm.vm_asm.special_objects[@intFromEnum(objects.SpecialObject.callback_stub)] = layouts.false_object;
    try testing.expect(heap.add(word_cell, 0, vm_ptr, t.vm) == null);

    try t.expectStackBalanced();
}
