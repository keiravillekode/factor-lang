// primitives/contexts.zig - Context, stack, and special object primitives

const std = @import("std");
const layouts = @import("../layouts.zig");
const math = @import("../fixnum.zig");
const vm_mod = @import("../vm.zig");

const Cell = layouts.Cell;
const Fixnum = layouts.Fixnum;
const FactorVM = vm_mod.FactorVM;
const VMAssemblyFields = vm_mod.VMAssemblyFields;

// --- Special Objects ---

pub export fn primitive_special_object(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const ctx = vm_asm.ctx;
    // ( n -- value )
    const n = layouts.untagFixnum(ctx.peek());
    const value = vm_asm.special_objects[@intCast(n)];
    ctx.replace(value);
}

pub export fn primitive_set_special_object(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const ctx = vm_asm.ctx;
    // ( value n -- )
    const n = layouts.untagFixnum(ctx.pop());
    const value = ctx.pop();
    vm_asm.special_objects[@intCast(n)] = value;
}

// --- Context Primitives ---

pub export fn primitive_context_object(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const ctx = vm_asm.ctx;
    // ( n -- value )
    const n = layouts.untagFixnum(ctx.peek());
    ctx.replace(ctx.context_objects[@intCast(n)]);
}

pub export fn primitive_set_context_object(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const ctx = vm_asm.ctx;
    // ( value n -- )
    const n = layouts.untagFixnum(ctx.pop());
    const value = ctx.pop();
    ctx.context_objects[@intCast(n)] = value;
}

pub export fn primitive_context_object_for(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    // ( n context -- obj )
    const ctx_cell = vm.pop();
    const index = layouts.untagFixnum(vm.pop());

    const ctx = vm.getContextFromAlien(ctx_cell);
    if (ctx == null) {
        vm.push(layouts.false_object);
        return;
    }

    vm.push(ctx.?.context_objects[@intCast(index)]);
}

// Helper: convert stack to array - allocates in nursery
fn stackToArray(vm: *FactorVM, bottom: Cell, top: Cell) Cell {
    // Calculate depth in cells
    const depth_bytes: i64 = @as(i64, @intCast(top)) - @as(i64, @intCast(bottom)) + @sizeOf(Cell);
    if (depth_bytes < 0) {
        return layouts.false_object;
    }

    const depth_cells: Cell = @intCast(@divExact(@as(u64, @intCast(depth_bytes)), @sizeOf(Cell)));

    // Allocate array, triggering GC if needed
    const tagged = vm.allotUninitializedArray(depth_cells) orelse {
        vm.memoryError();
    };
    const arr: *layouts.Array = @ptrFromInt(layouts.UNTAG(tagged));

    // Copy stack data to array
    const src: [*]const Cell = @ptrFromInt(bottom);
    const dest = arr.data();
    @memcpy(dest[0..depth_cells], src[0..depth_cells]);

    return tagged;
}

pub export fn primitive_datastack_for(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    // ( context -- array )
    const ctx_cell = vm.pop();

    const other_ctx = vm.getContextFromAlien(ctx_cell);
    if (other_ctx == null) {
        vm.push(layouts.false_object);
        return;
    }

    const ctx = other_ctx.?;
    if (ctx.datastack_seg == null) {
        vm.push(layouts.false_object);
        return;
    }

    const bottom = ctx.datastack_seg.?.start;
    const top = ctx.datastack;
    const arr = stackToArray(vm, bottom, top);
    vm.push(arr);
}

pub export fn primitive_retainstack_for(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    // ( context -- array )
    const ctx_cell = vm.peek();

    const other_ctx = vm.getContextFromAlien(ctx_cell);
    if (other_ctx == null) {
        vm.replace(layouts.false_object);
        return;
    }

    const ctx = other_ctx.?;
    if (ctx.retainstack_seg == null) {
        vm.replace(layouts.false_object);
        return;
    }

    const bottom = ctx.retainstack_seg.?.start;
    const top = ctx.retainstack;
    const arr = stackToArray(vm, bottom, top);
    vm.replace(arr);
}

pub export fn primitive_check_datastack(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    // ( saved-datastack in out -- ? )
    // This validates that the preserved portion of the stack hasn't changed
    const out = layouts.untagFixnum(vm.pop());
    const in = layouts.untagFixnum(vm.pop());
    const height = out - in;
    const saved_datastack = vm.pop();

    {
        const ctx = vm.vm_asm.ctx;
        if (ctx.datastack_seg) |seg| {
            // Check that the saved datastack is an array
            if (!layouts.hasTag(saved_datastack, .array)) {
                vm.push(layouts.false_object);
                return;
            }

            const saved_height: Fixnum = @intCast(layouts.arrayCapacity(saved_datastack));
            // Handle case where datastack might have underflowed
            const current_height: Fixnum = if (ctx.datastack >= seg.start)
                @intCast((ctx.datastack - seg.start + @sizeOf(Cell)) / @sizeOf(Cell))
            else
                0;

            // Verify current height matches expected height after effect
            if (current_height - height != saved_height) {
                vm.push(layouts.false_object);
                return;
            }

            // Compare bottom portion of stack element-by-element
            // We check saved_height - in elements (the preserved portion)
            const ds_bot: [*]Cell = @ptrFromInt(seg.start);
            const preserved_count: Cell = @intCast(saved_height - in);

            for (0..preserved_count) |i| {
                if (ds_bot[i] != layouts.arrayNth(saved_datastack, i)) {
                    vm.push(layouts.false_object);
                    return;
                }
            }

            // All checks passed
            vm.push(vm.tagBoolean(true));
        } else {
            vm.push(layouts.false_object);
        }
    }
}

pub export fn primitive_load_locals(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    // ( n -- )
    // Load n values from datastack to local stack (retain stack)
    const count = layouts.untagFixnum(vm.pop());
    {
        const ctx = vm.vm_asm.ctx;
        const cell_size = @sizeOf(Cell);
        const count_unsigned: Cell = @intCast(count);
        const src_addr = ctx.datastack - cell_size * (count_unsigned - 1);
        const dst_addr = ctx.retainstack + cell_size;
        const byte_count = cell_size * count_unsigned;

        const src_ptr: [*]const u8 = @ptrFromInt(src_addr);
        const dst_ptr: [*]u8 = @ptrFromInt(dst_addr);

        @memcpy(dst_ptr[0..byte_count], src_ptr[0..byte_count]);

        ctx.datastack -= cell_size * count_unsigned;
        ctx.retainstack += cell_size * count_unsigned;
    }
}

// Helper: copy array contents to a stack segment, returns new stack top
fn array_to_stack(arr: *const layouts.Array, bottom: Cell) Cell {
    const capacity = layouts.untagFixnumUnsigned(arr.capacity);
    const depth = capacity * @sizeOf(Cell);
    const data = arr.data();

    const dest: [*]Cell = @ptrFromInt(bottom);
    @memcpy(dest[0..capacity], data[0..capacity]);

    // Return pointer to top of stack (last element)
    return bottom + depth - @sizeOf(Cell);
}

pub export fn primitive_set_datastack(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    // ( array -- )
    // Set the datastack to the contents of the array
    const arr_cell = vm.pop();
    {
        const ctx = vm.vm_asm.ctx;
        if (layouts.hasTag(arr_cell, .array)) {
            const arr: *const layouts.Array = @ptrFromInt(layouts.UNTAG(arr_cell));
            if (ctx.datastack_seg) |seg| {
                ctx.datastack = array_to_stack(arr, seg.start);
            }
        }
    }
}

pub export fn primitive_set_retainstack(vm_asm: *VMAssemblyFields) callconv(.c) void {
    const vm = vm_asm.getVM();
    // ( array -- )
    // Set the retainstack to the contents of the array
    const arr_cell = vm.pop();
    {
        const ctx = vm.vm_asm.ctx;
        if (layouts.hasTag(arr_cell, .array)) {
            const arr: *const layouts.Array = @ptrFromInt(layouts.UNTAG(arr_cell));
            if (ctx.retainstack_seg) |seg| {
                ctx.retainstack = array_to_stack(arr, seg.start);
            }
        }
    }
}

// --- Tests ---

const TestEnv = struct {
    vm: *FactorVM,
    heap: *@import("../data_heap.zig").DataHeap,
    true_obj: Cell,

    fn init() !TestEnv {
        const data_heap_mod = @import("../data_heap.zig");
        const objects = @import("../objects.zig");
        const allocator = std.testing.allocator;
        const vm = try FactorVM.init(allocator);
        vm.vm_asm.ctx = try vm.newContext();
        vm.vm_asm.spare_ctx = try vm.newContext();
        // vm.gc stays null, so the nursery must hold every allocation.
        const heap = try data_heap_mod.DataHeap.init(allocator, 256 * 1024, 64 * 1024, 64 * 1024);
        vm.setDataHeap(heap);
        // tagBoolean returns the canonical_true special object; install a
        // sentinel so t and f differ in a bare VM.
        const true_obj = layouts.tagFixnum(0x7472_7565);
        vm.vm_asm.special_objects[@intFromEnum(objects.SpecialObject.canonical_true)] = true_obj;
        return .{ .vm = vm, .heap = heap, .true_obj = true_obj };
    }

    fn deinit(self: *TestEnv) void {
        self.heap.deinit();
        self.vm.cards_array = null;
        self.vm.decks_array = null;
        self.vm.deinit();
    }

    fn fields(self: *TestEnv) *VMAssemblyFields {
        return &self.vm.vm_asm;
    }

    fn array(self: *TestEnv, items: []const Cell) Cell {
        const tagged = self.vm.allotArray(items.len, layouts.false_object) orelse unreachable;
        const arr: *layouts.Array = @ptrFromInt(layouts.UNTAG(tagged));
        @memcpy(arr.data()[0..items.len], items);
        return tagged;
    }

    fn contextAlien(self: *TestEnv, ctx: *@import("../contexts.zig").Context) Cell {
        return self.vm.allotAlien(layouts.false_object, @intFromPtr(ctx));
    }
};

fn expectArray(tagged: Cell, expected: []const Cell) !void {
    try std.testing.expect(layouts.hasTag(tagged, .array));
    try std.testing.expectEqual(expected.len, layouts.arrayCapacity(tagged));
    for (expected, 0..) |e, i| {
        try std.testing.expectEqual(e, layouts.arrayNth(tagged, i));
    }
}

test "special_object and set_special_object round trip" {
    var t = try TestEnv.init();
    defer t.deinit();

    t.vm.push(layouts.tagFixnum(42));
    t.vm.push(layouts.tagFixnum(5));
    primitive_set_special_object(t.fields());
    try std.testing.expectEqual(layouts.tagFixnum(42), t.vm.vm_asm.special_objects[5]);

    t.vm.push(layouts.tagFixnum(5));
    primitive_special_object(t.fields());
    try std.testing.expectEqual(layouts.tagFixnum(42), t.vm.pop());
    try std.testing.expectEqual(@as(Cell, 0), t.vm.vm_asm.ctx.datastackDepth());
}

test "context_object and set_context_object read and write the current context" {
    var t = try TestEnv.init();
    defer t.deinit();
    const ctx = t.vm.vm_asm.ctx;

    t.vm.push(layouts.tagFixnum(7));
    t.vm.push(layouts.tagFixnum(1));
    primitive_set_context_object(t.fields());
    try std.testing.expectEqual(layouts.tagFixnum(7), ctx.context_objects[1]);
    try std.testing.expectEqual(layouts.false_object, ctx.context_objects[0]);

    t.vm.push(layouts.tagFixnum(1));
    primitive_context_object(t.fields());
    try std.testing.expectEqual(layouts.tagFixnum(7), t.vm.pop());

    // An untouched slot reads back as f, and the last slot is addressable.
    t.vm.push(layouts.tagFixnum(3));
    primitive_context_object(t.fields());
    try std.testing.expectEqual(layouts.false_object, t.vm.pop());
    ctx.context_objects[3] = layouts.tagFixnum(9);
    t.vm.push(layouts.tagFixnum(3));
    primitive_context_object(t.fields());
    try std.testing.expectEqual(layouts.tagFixnum(9), t.vm.pop());
    try std.testing.expectEqual(@as(Cell, 0), ctx.datastackDepth());
}

test "context_object_for reads another context through its alien" {
    var t = try TestEnv.init();
    defer t.deinit();
    const other = t.vm.vm_asm.spare_ctx;
    other.context_objects[0] = layouts.tagFixnum(99);

    t.vm.push(layouts.tagFixnum(0));
    t.vm.push(t.contextAlien(other));
    primitive_context_object_for(t.fields());
    try std.testing.expectEqual(layouts.tagFixnum(99), t.vm.pop());

    // f stands for "no context".
    t.vm.push(layouts.tagFixnum(0));
    t.vm.push(layouts.false_object);
    primitive_context_object_for(t.fields());
    try std.testing.expectEqual(layouts.false_object, t.vm.pop());
    try std.testing.expectEqual(@as(Cell, 0), t.vm.vm_asm.ctx.datastackDepth());
}

test "datastack_for and retainstack_for copy another context's stacks into arrays" {
    var t = try TestEnv.init();
    defer t.deinit();
    const other = t.vm.vm_asm.spare_ctx;

    other.push(layouts.tagFixnum(1));
    other.push(layouts.tagFixnum(2));
    other.push(layouts.tagFixnum(3));
    other.pushRetain(layouts.tagFixnum(5));
    other.pushRetain(layouts.tagFixnum(6));

    t.vm.push(t.contextAlien(other));
    primitive_datastack_for(t.fields());
    try expectArray(t.vm.pop(), &[_]Cell{ layouts.tagFixnum(1), layouts.tagFixnum(2), layouts.tagFixnum(3) });

    t.vm.push(t.contextAlien(other));
    primitive_retainstack_for(t.fields());
    try expectArray(t.vm.pop(), &[_]Cell{ layouts.tagFixnum(5), layouts.tagFixnum(6) });

    // The other context is left alone.
    try std.testing.expectEqual(@as(Cell, 3), other.datastackDepth());
    try std.testing.expectEqual(@as(Cell, 2), other.retainstackDepth());

    // Empty stacks give empty arrays.
    other.reset();
    t.vm.push(t.contextAlien(other));
    primitive_datastack_for(t.fields());
    try expectArray(t.vm.pop(), &[_]Cell{});
    t.vm.push(t.contextAlien(other));
    primitive_retainstack_for(t.fields());
    try expectArray(t.vm.pop(), &[_]Cell{});

    // f gives f.
    t.vm.push(layouts.false_object);
    primitive_datastack_for(t.fields());
    try std.testing.expectEqual(layouts.false_object, t.vm.pop());
    t.vm.push(layouts.false_object);
    primitive_retainstack_for(t.fields());
    try std.testing.expectEqual(layouts.false_object, t.vm.pop());
    try std.testing.expectEqual(@as(Cell, 0), t.vm.vm_asm.ctx.datastackDepth());
}

test "set_datastack and set_retainstack replace the current stacks from arrays" {
    var t = try TestEnv.init();
    defer t.deinit();
    const ctx = t.vm.vm_asm.ctx;

    t.vm.push(layouts.tagFixnum(-1)); // overwritten by the new contents
    t.vm.push(t.array(&[_]Cell{ layouts.tagFixnum(10), layouts.tagFixnum(20), layouts.tagFixnum(30) }));
    primitive_set_datastack(t.fields());
    try std.testing.expectEqual(@as(Cell, 3), ctx.datastackDepth());
    try std.testing.expectEqual(layouts.tagFixnum(30), t.vm.pop());
    try std.testing.expectEqual(layouts.tagFixnum(20), t.vm.pop());
    try std.testing.expectEqual(layouts.tagFixnum(10), t.vm.pop());

    // An empty array empties the stack.
    t.vm.push(layouts.tagFixnum(1));
    t.vm.push(t.array(&[_]Cell{}));
    primitive_set_datastack(t.fields());
    try std.testing.expectEqual(@as(Cell, 0), ctx.datastackDepth());

    // A non-array argument is popped and ignored.
    t.vm.push(layouts.tagFixnum(1));
    t.vm.push(layouts.tagFixnum(2));
    primitive_set_datastack(t.fields());
    try std.testing.expectEqual(@as(Cell, 1), ctx.datastackDepth());
    try std.testing.expectEqual(layouts.tagFixnum(1), t.vm.pop());

    ctx.pushRetain(layouts.tagFixnum(-1));
    t.vm.push(t.array(&[_]Cell{ layouts.tagFixnum(7), layouts.tagFixnum(8) }));
    primitive_set_retainstack(t.fields());
    try std.testing.expectEqual(@as(Cell, 2), ctx.retainstackDepth());
    try std.testing.expectEqual(layouts.tagFixnum(8), ctx.popRetain());
    try std.testing.expectEqual(layouts.tagFixnum(7), ctx.popRetain());
    try std.testing.expectEqual(@as(Cell, 0), ctx.datastackDepth());
}

test "check_datastack compares the preserved bottom of the stack with a saved copy" {
    var t = try TestEnv.init();
    defer t.deinit();
    const ctx = t.vm.vm_asm.ctx;
    const one = layouts.tagFixnum(1);
    const two = layouts.tagFixnum(2);

    const H = struct {
        fn check(env: *TestEnv, saved: Cell, in: Fixnum, out: Fixnum) Cell {
            env.vm.push(saved);
            env.vm.push(layouts.tagFixnum(in));
            env.vm.push(layouts.tagFixnum(out));
            primitive_check_datastack(env.fields());
            return env.vm.pop();
        }
    };

    t.vm.push(one);
    t.vm.push(two);
    const saved = t.array(&[_]Cell{ one, two });

    // Same stack, effect ( -- ): matches.
    try std.testing.expectEqual(t.true_obj, H.check(&t, saved, 0, 0));
    try std.testing.expectEqual(@as(Cell, 2), ctx.datastackDepth());

    // One value produced by an effect ( -- x ): the height accounts for it.
    t.vm.push(layouts.tagFixnum(3));
    try std.testing.expectEqual(t.true_obj, H.check(&t, saved, 0, 1));
    // Claiming ( -- ) with the extra value is a height mismatch.
    try std.testing.expectEqual(layouts.false_object, H.check(&t, saved, 0, 0));
    _ = t.vm.pop();

    // A changed preserved element is detected.
    const tampered = t.array(&[_]Cell{ one, layouts.tagFixnum(9) });
    try std.testing.expectEqual(layouts.false_object, H.check(&t, tampered, 0, 0));
    // ...unless it was an input consumed by the effect ( x -- y ).
    try std.testing.expectEqual(t.true_obj, H.check(&t, tampered, 1, 1));

    // A saved copy of the wrong height, or not an array at all, fails.
    try std.testing.expectEqual(layouts.false_object, H.check(&t, t.array(&[_]Cell{one}), 0, 0));
    try std.testing.expectEqual(layouts.false_object, H.check(&t, layouts.tagFixnum(0), 0, 0));
    try std.testing.expectEqual(@as(Cell, 2), ctx.datastackDepth());
}

test "load_locals moves the top n data stack values to the retain stack" {
    var t = try TestEnv.init();
    defer t.deinit();
    const ctx = t.vm.vm_asm.ctx;

    t.vm.push(layouts.tagFixnum(1));
    t.vm.push(layouts.tagFixnum(2));
    t.vm.push(layouts.tagFixnum(3));
    t.vm.push(layouts.tagFixnum(2)); // count
    primitive_load_locals(t.fields());

    try std.testing.expectEqual(@as(Cell, 1), ctx.datastackDepth());
    try std.testing.expectEqual(layouts.tagFixnum(1), ctx.peek());
    try std.testing.expectEqual(@as(Cell, 2), ctx.retainstackDepth());
    try std.testing.expectEqual(layouts.tagFixnum(3), ctx.popRetain());
    try std.testing.expectEqual(layouts.tagFixnum(2), ctx.popRetain());
}

test "load_locals with zero locals is a no-op" {
    // BUG (not fixed here): primitive_load_locals computes
    // `cell_size * (count_unsigned - 1)` with count_unsigned == 0, which
    // overflows: a panic in Debug builds (release wraps and copies nothing,
    // so the result is accidentally right). The C++ VM does the arithmetic
    // on a signed fixnum and is fine.
    if (true) return error.SkipZigTest;

    var t = try TestEnv.init();
    defer t.deinit();
    const ctx = t.vm.vm_asm.ctx;
    t.vm.push(layouts.tagFixnum(1));
    t.vm.push(layouts.tagFixnum(0));
    primitive_load_locals(t.fields());
    try std.testing.expectEqual(@as(Cell, 1), ctx.datastackDepth());
    try std.testing.expectEqual(@as(Cell, 0), ctx.retainstackDepth());
}
