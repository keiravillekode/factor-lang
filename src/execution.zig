// Fallback interpreter for startup quotations that have no compiled entry
// point (boot image before JIT, tests). Production path is vm.cToFactor.
// Intentionally limited: do not grow this into a second execution engine.
const std = @import("std");

const contexts = @import("contexts.zig");
const layouts = @import("layouts.zig");
const objects = @import("objects.zig");
const primitives = @import("primitives.zig");
const vm_mod = @import("vm.zig");

const Cell = layouts.Cell;
const Fixnum = layouts.Fixnum;
const FactorVM = vm_mod.FactorVM;

pub const ExecutionError = error{
    StackUnderflow,
    StackOverflow,
    InvalidQuotation,
    InvalidWord,
    UndefinedWord,
    TypeError,
    NotImplemented,
};

pub const Interpreter = struct {
    vm: *FactorVM,
    recursion_depth: u32,

    const max_recursion_depth: u32 = 100000;
    const Self = @This();

    pub fn init(vm: *FactorVM) Self {
        return Self{ .vm = vm, .recursion_depth = 0 };
    }

    pub fn executeQuotation(self: *Self, quot_cell: Cell) ExecutionError!void {
        self.recursion_depth += 1;
        defer self.recursion_depth -= 1;

        if (self.recursion_depth > max_recursion_depth) {
            return ExecutionError.StackOverflow;
        }

        if (!layouts.hasTag(quot_cell, .quotation)) {
            return ExecutionError.InvalidQuotation;
        }

        const quot: *const layouts.Quotation = @ptrFromInt(layouts.UNTAG(quot_cell));
        const arr_cell = quot.array;

        if (!layouts.hasTag(arr_cell, .array)) {
            return ExecutionError.InvalidQuotation;
        }

        const arr: *const layouts.Array = @ptrFromInt(layouts.UNTAG(arr_cell));
        const len = layouts.untagFixnumUnsigned(arr.capacity);

        if (len > 1000) {
            return ExecutionError.InvalidQuotation;
        }

        const data = arr.data();

        if (len == 4 and self.isMegaCacheLookupPattern(data[0..4], len)) {
            try self.executeMegaCacheLookup(data[0..4]);
            return;
        }

        for (0..len) |i| {
            const elem = data[i];
            try self.executeElement(elem);
        }
    }

    fn isMegaCacheLookupPattern(self: *Self, data: []const Cell, len: Cell) bool {
        if (len != 4) return false;

        if (!layouts.hasTag(data[0], .array)) return false;
        if (!layouts.hasTag(data[1], .fixnum)) return false;
        if (!layouts.hasTag(data[2], .array)) return false;
        if (!layouts.hasTag(data[3], .word)) return false;

        const mega_lookup_word = self.vm.vm_asm.special_objects[@intFromEnum(objects.SpecialObject.mega_lookup_word)];
        return data[3] == mega_lookup_word;
    }

    fn executeMegaCacheLookup(self: *Self, data: []const Cell) ExecutionError!void {
        const ctx = self.vm.vm_asm.ctx;

        const methods_cell = data[0];
        const index_fixnum = data[1];
        const index = layouts.untagFixnum(index_fixnum);

        const index_usize: usize = @intCast(index);
        const obj_addr = ctx.datastack - (index_usize * @sizeOf(Cell));
        const obj = @as(*const Cell, @ptrFromInt(obj_addr)).*;

        const method = primitives.lookupMethod(obj, methods_cell);

        const method_tag = layouts.typeTag(method);
        switch (method_tag) {
            .quotation => try self.executeQuotation(method),
            .word => try self.executeWord(method),
            else => return ExecutionError.TypeError,
        }
    }

    fn executeElement(self: *Self, elem: Cell) ExecutionError!void {
        const tag = layouts.typeTag(elem);

        switch (tag) {
            .word => try self.executeWord(elem),
            .quotation => {
                self.vm.push(elem);
            },
            .wrapper => {
                const wrapper: *const layouts.Wrapper = @ptrFromInt(layouts.UNTAG(elem));
                self.vm.push(wrapper.object);
            },
            else => {
                self.vm.push(elem);
            },
        }
    }

    fn executeWord(self: *Self, word_cell: Cell) ExecutionError!void {
        const word: *const layouts.Word = @ptrFromInt(layouts.UNTAG(word_cell));

        if (try self.tryExecuteBuiltin(word)) return;

        const def = word.def;
        if (def == layouts.false_object) {
            return ExecutionError.UndefinedWord;
        }

        if (layouts.hasTag(def, .quotation)) {
            const quot: *const layouts.Quotation = @ptrFromInt(layouts.UNTAG(def));
            if (quot.array != layouts.false_object and layouts.hasTag(quot.array, .array)) {
                const arr: *const layouts.Array = @ptrFromInt(layouts.UNTAG(quot.array));
                const arr_len = layouts.untagFixnumUnsigned(arr.capacity);
                if (arr_len > 0 and arr.data()[0] == word_cell) {
                    @panic("Sub-primitive word not implemented - would cause infinite recursion");
                }
            }
        }

        try self.executeQuotation(def);
    }

    fn wordNameEquals(word: *const layouts.Word, target: []const u8) bool {
        if (word.name == layouts.false_object) return false;
        if (!layouts.hasTag(word.name, .string)) return false;
        const str: *const layouts.String = @ptrFromInt(layouts.UNTAG(word.name));
        const len = layouts.untagFixnumUnsigned(str.length);
        if (len != target.len) return false;
        const data = str.data();
        for (0..len) |i| {
            const ch: u8 = @truncate(data[i]);
            if (ch != target[i]) return false;
        }
        return true;
    }

    fn trueObject(self: *Self) Cell {
        return self.vm.vm_asm.special_objects[@intFromEnum(objects.SpecialObject.canonical_true)];
    }

    fn boolObject(self: *Self, cond: bool) Cell {
        return if (cond) self.trueObject() else layouts.false_object;
    }

    fn tryExecuteBuiltin(self: *Self, word: *const layouts.Word) ExecutionError!bool {
        const ctx = self.vm.vm_asm.ctx;

        if (wordNameEquals(word, "swap")) {
            const y = ctx.pop();
            const x = ctx.pop();
            ctx.push(y);
            ctx.push(x);
        } else if (wordNameEquals(word, "dup")) {
            ctx.push(ctx.peek());
        } else if (wordNameEquals(word, "drop")) {
            _ = ctx.pop();
        } else if (wordNameEquals(word, "over")) {
            const y = ctx.pop();
            const x = ctx.peek();
            ctx.push(y);
            ctx.push(x);
        } else if (wordNameEquals(word, "rot")) {
            const z = ctx.pop();
            const y = ctx.pop();
            const x = ctx.pop();
            ctx.push(y);
            ctx.push(z);
            ctx.push(x);
        } else if (wordNameEquals(word, "-rot")) {
            const z = ctx.pop();
            const y = ctx.pop();
            const x = ctx.pop();
            ctx.push(z);
            ctx.push(x);
            ctx.push(y);
        } else if (wordNameEquals(word, "2dup")) {
            const y = ctx.pop();
            const x = ctx.peek();
            ctx.push(y);
            ctx.push(x);
            ctx.push(y);
        } else if (wordNameEquals(word, "2drop")) {
            _ = ctx.pop();
            _ = ctx.pop();
        } else if (wordNameEquals(word, "3dup")) {
            const z = ctx.pop();
            const y = ctx.pop();
            const x = ctx.peek();
            ctx.push(y);
            ctx.push(z);
            ctx.push(x);
            ctx.push(y);
            ctx.push(z);
        } else if (wordNameEquals(word, "pick")) {
            const z = ctx.pop();
            const y = ctx.pop();
            const x = ctx.peek();
            ctx.push(y);
            ctx.push(z);
            ctx.push(x);
        } else if (wordNameEquals(word, "nip")) {
            const y = ctx.pop();
            _ = ctx.pop();
            ctx.push(y);
        } else if (wordNameEquals(word, "dupd")) {
            const y = ctx.pop();
            const x = ctx.peek();
            ctx.push(x);
            ctx.push(y);
        } else if (wordNameEquals(word, "swapd")) {
            const z = ctx.pop();
            const y = ctx.pop();
            const x = ctx.pop();
            ctx.push(y);
            ctx.push(x);
            ctx.push(z);
        } else if (wordNameEquals(word, "die")) {
            primitives.callPrimitive(self.vm, @intFromEnum(primitives.PrimitiveIndex.die));
        } else if (wordNameEquals(word, "call")) {
            try self.executeQuotation(ctx.pop());
        } else if (wordNameEquals(word, "dip")) {
            const quot = ctx.pop();
            const x = ctx.pop();
            try self.executeQuotation(quot);
            ctx.push(x);
        } else if (wordNameEquals(word, "keep")) {
            const quot = ctx.pop();
            const x = ctx.peek();
            try self.executeQuotation(quot);
            ctx.push(x);
        } else if (wordNameEquals(word, "if")) {
            const false_quot = ctx.pop();
            const true_quot = ctx.pop();
            const cond = ctx.pop();
            try self.executeQuotation(if (cond == layouts.false_object) false_quot else true_quot);
        } else if (wordNameEquals(word, "?")) {
            const false_val = ctx.pop();
            const true_val = ctx.pop();
            const cond = ctx.pop();
            ctx.push(if (cond == layouts.false_object) false_val else true_val);
        } else if (wordNameEquals(word, "do-primitive")) {
            const prim_idx = ctx.pop();
            primitives.callPrimitive(self.vm, @intCast(layouts.untagFixnum(prim_idx)));
        } else if (wordNameEquals(word, "all-instances")) {
            primitives.callPrimitive(self.vm, @intFromEnum(primitives.PrimitiveIndex.all_instances));
        } else if (wordNameEquals(word, "special-object")) {
            primitives.callPrimitive(self.vm, @intFromEnum(primitives.PrimitiveIndex.special_object));
        } else if (wordNameEquals(word, "fwrite")) {
            primitives.callPrimitive(self.vm, @intFromEnum(primitives.PrimitiveIndex.fwrite));
        } else if (wordNameEquals(word, "fflush")) {
            primitives.callPrimitive(self.vm, @intFromEnum(primitives.PrimitiveIndex.fflush));
        } else if (wordNameEquals(word, "tag")) {
            ctx.push(layouts.tagFixnum(@intCast(layouts.TAG(ctx.pop()))));
        } else if (wordNameEquals(word, "length")) {
            const seq = ctx.pop();
            const tag = layouts.typeTag(seq);
            const addr = layouts.UNTAG(seq);
            const len: u64 = switch (tag) {
                .array => layouts.untagFixnumUnsigned(@as(*const layouts.Array, @ptrFromInt(addr)).capacity),
                .string => layouts.untagFixnumUnsigned(@as(*const layouts.String, @ptrFromInt(addr)).length),
                .byte_array => layouts.untagFixnumUnsigned(@as(*const layouts.ByteArray, @ptrFromInt(addr)).capacity),
                .quotation => blk: {
                    const quot: *const layouts.Quotation = @ptrFromInt(addr);
                    const arr: *const layouts.Array = @ptrFromInt(layouts.UNTAG(quot.array));
                    break :blk layouts.untagFixnumUnsigned(arr.capacity);
                },
                else => 0,
            };
            ctx.push(layouts.tagFixnum(@intCast(len)));
        } else if (wordNameEquals(word, "fixnum+") or wordNameEquals(word, "fixnum+fast")) {
            const y = ctx.pop();
            const x = ctx.pop();
            ctx.push(layouts.tagFixnum(layouts.untagFixnum(x) +% layouts.untagFixnum(y)));
        } else if (wordNameEquals(word, "fixnum-") or wordNameEquals(word, "fixnum-fast")) {
            const y = ctx.pop();
            const x = ctx.pop();
            ctx.push(layouts.tagFixnum(layouts.untagFixnum(x) -% layouts.untagFixnum(y)));
        } else if (wordNameEquals(word, "fixnum*") or wordNameEquals(word, "fixnum*fast")) {
            const y = ctx.pop();
            const x = ctx.pop();
            ctx.push(layouts.tagFixnum(layouts.untagFixnum(x) *% layouts.untagFixnum(y)));
        } else if (wordNameEquals(word, "fixnum-bitand")) {
            const y = ctx.pop();
            const x = ctx.pop();
            ctx.push(layouts.tagFixnum(layouts.untagFixnum(x) & layouts.untagFixnum(y)));
        } else if (wordNameEquals(word, "fixnum-bitor")) {
            const y = ctx.pop();
            const x = ctx.pop();
            ctx.push(layouts.tagFixnum(layouts.untagFixnum(x) | layouts.untagFixnum(y)));
        } else if (wordNameEquals(word, "fixnum-bitxor")) {
            const y = ctx.pop();
            const x = ctx.pop();
            ctx.push(layouts.tagFixnum(layouts.untagFixnum(x) ^ layouts.untagFixnum(y)));
        } else if (wordNameEquals(word, "fixnum-bitnot")) {
            ctx.push(layouts.tagFixnum(~layouts.untagFixnum(ctx.pop())));
        } else if (wordNameEquals(word, "fixnum-shift")) {
            const n_val = layouts.untagFixnum(ctx.pop());
            const x_val = layouts.untagFixnum(ctx.pop());
            const result = if (n_val >= 0)
                if (n_val < 64) x_val << @intCast(n_val) else @as(Fixnum, 0)
            else
                x_val >> @as(u6, @intCast(@min(63, -n_val)));
            ctx.push(layouts.tagFixnum(result));
        } else if (wordNameEquals(word, "fixnum<")) {
            const y = ctx.pop();
            const x = ctx.pop();
            ctx.push(self.boolObject(layouts.untagFixnum(x) < layouts.untagFixnum(y)));
        } else if (wordNameEquals(word, "fixnum<=")) {
            const y = ctx.pop();
            const x = ctx.pop();
            ctx.push(self.boolObject(layouts.untagFixnum(x) <= layouts.untagFixnum(y)));
        } else if (wordNameEquals(word, "fixnum>")) {
            const y = ctx.pop();
            const x = ctx.pop();
            ctx.push(self.boolObject(layouts.untagFixnum(x) > layouts.untagFixnum(y)));
        } else if (wordNameEquals(word, "fixnum>=")) {
            const y = ctx.pop();
            const x = ctx.pop();
            ctx.push(self.boolObject(layouts.untagFixnum(x) >= layouts.untagFixnum(y)));
        } else if (wordNameEquals(word, "both-fixnums?")) {
            const y = ctx.pop();
            const x = ctx.pop();
            ctx.push(self.boolObject(layouts.hasTag(x, .fixnum) and layouts.hasTag(y, .fixnum)));
        } else if (wordNameEquals(word, "eq?")) {
            const y = ctx.pop();
            const x = ctx.pop();
            ctx.push(self.boolObject(x == y));
        } else {
            return false;
        }
        return true;
    }

    pub fn call(self: *Self) ExecutionError!void {
        const quot = self.vm.pop();
        try self.executeQuotation(quot);
    }

    pub fn execute(self: *Self) ExecutionError!void {
        const word = self.vm.pop();
        try self.executeWord(word);
    }

    pub fn ifCombinator(self: *Self) ExecutionError!void {
        const false_quot = self.vm.pop();
        const true_quot = self.vm.pop();
        const cond = self.vm.pop();

        if (cond != layouts.false_object) {
            try self.executeQuotation(true_quot);
        } else {
            try self.executeQuotation(false_quot);
        }
    }

    pub fn dip(self: *Self) ExecutionError!void {
        const ctx = self.vm.vm_asm.ctx;
        const quot = ctx.pop();
        const x = ctx.pop();
        ctx.pushRetain(x);
        try self.executeQuotation(quot);
        const x_restored = ctx.popRetain();
        ctx.push(x_restored);
    }

    pub fn keep(self: *Self) ExecutionError!void {
        const ctx = self.vm.vm_asm.ctx;
        const quot = ctx.pop();
        const x = ctx.peek();
        ctx.pushRetain(x);
        try self.executeQuotation(quot);
        const x_restored = ctx.popRetain();
        ctx.push(x_restored);
    }
};

pub fn runFactor(vm: *FactorVM) !void {
    const startup_quot = vm.specialObject(objects.SpecialObject.startup_quot);

    if (startup_quot == layouts.false_object) {
        return;
    }

    if (layouts.hasTag(startup_quot, .quotation)) {
        const quot: *const layouts.Quotation = @ptrFromInt(layouts.UNTAG(startup_quot));

        if (quot.entry_point != 0) {
            vm.cToFactor(startup_quot);
            return;
        }
    }

    var interp = Interpreter.init(vm);
    try interp.executeQuotation(startup_quot);
}

test "interpreter basic literals" {
    const allocator = std.testing.allocator;
    var vm = try FactorVM.init(allocator);
    defer vm.deinit();

    vm.vm_asm.ctx = try vm.newContext();
    vm.vm_asm.spare_ctx = try vm.newContext();

    var interp = Interpreter.init(vm);

    try interp.executeElement(layouts.tagFixnum(42));

    const result = vm.pop();
    try std.testing.expectEqual(layouts.tagFixnum(42), result);
}

// --- Interpreter tests ---

const InterpTestVM = struct {
    vm: *FactorVM,
    heap: *@import("data_heap.zig").DataHeap,
    true_obj: Cell,

    fn init() !InterpTestVM {
        const data_heap_mod = @import("data_heap.zig");
        const allocator = std.testing.allocator;
        const vm = try FactorVM.init(allocator);
        vm.vm_asm.ctx = try vm.newContext();
        vm.vm_asm.spare_ctx = try vm.newContext();
        const heap = try data_heap_mod.DataHeap.init(allocator, 256 * 1024, 64 * 1024, 64 * 1024);
        vm.setDataHeap(heap);
        const true_obj = layouts.tagFixnum(0x7472_7565);
        vm.vm_asm.special_objects[@intFromEnum(objects.SpecialObject.canonical_true)] = true_obj;
        return .{ .vm = vm, .heap = heap, .true_obj = true_obj };
    }

    fn deinit(self: *InterpTestVM) void {
        self.heap.deinit();
        self.vm.cards_array = null;
        self.vm.decks_array = null;
        self.vm.deinit();
    }

    fn string(self: *InterpTestVM, text: []const u8) Cell {
        const tagged = self.vm.allotObject(.string, @sizeOf(layouts.String) + text.len) orelse @panic("OOM");
        const str: *layouts.String = @ptrFromInt(layouts.UNTAG(tagged));
        str.length = layouts.tagFixnum(@intCast(text.len));
        str.aux = layouts.false_object;
        str.hashcode_field = layouts.tagFixnum(0);
        @memcpy(str.data()[0..text.len], text);
        return tagged;
    }

    fn word(self: *InterpTestVM, name: []const u8, def: Cell) Cell {
        const name_cell = self.string(name);
        const tagged = self.vm.allotObject(.word, @sizeOf(layouts.Word)) orelse @panic("OOM");
        const w: *layouts.Word = @ptrFromInt(layouts.UNTAG(tagged));
        w.hashcode_field = layouts.tagFixnum(0);
        w.name = name_cell;
        w.vocabulary = layouts.false_object;
        w.def = def;
        w.props = layouts.false_object;
        w.pic_def = layouts.false_object;
        w.pic_tail_def = layouts.false_object;
        w.subprimitive = layouts.false_object;
        w.entry_point = 0;
        return tagged;
    }

    fn builtin(self: *InterpTestVM, name: []const u8) Cell {
        return self.word(name, layouts.false_object);
    }

    fn quotation(self: *InterpTestVM, elems: []const Cell) Cell {
        const arr = self.vm.allotArray(elems.len, layouts.false_object) orelse @panic("OOM");
        const a: *layouts.Array = @ptrFromInt(layouts.UNTAG(arr));
        @memcpy(a.data()[0..elems.len], elems);
        const tagged = self.vm.allotObject(.quotation, @sizeOf(layouts.Quotation)) orelse @panic("OOM");
        const q: *layouts.Quotation = @ptrFromInt(layouts.UNTAG(tagged));
        q.array = arr;
        q.cached_effect = layouts.false_object;
        q.cache_counter = layouts.false_object;
        q.entry_point = 0;
        return tagged;
    }

    fn wrapper(self: *InterpTestVM, obj: Cell) Cell {
        const tagged = self.vm.allotObject(.wrapper, @sizeOf(layouts.Wrapper)) orelse @panic("OOM");
        const w: *layouts.Wrapper = @ptrFromInt(layouts.UNTAG(tagged));
        w.object = obj;
        return tagged;
    }

    fn run(self: *InterpTestVM, quot: Cell) ExecutionError!void {
        var interp = Interpreter.init(self.vm);
        try interp.executeQuotation(quot);
        std.debug.assert(interp.recursion_depth == 0);
    }

    fn depth(self: *InterpTestVM) Cell {
        return self.vm.vm_asm.ctx.datastackDepth();
    }

    fn reset(self: *InterpTestVM) void {
        self.vm.vm_asm.ctx.resetDatastack();
    }

    /// Run `[ inputs... word ]` and check the stack equals `outputs`.
    fn expectStack(self: *InterpTestVM, word_name: []const u8, inputs: []const Cell, outputs: []const Cell) !void {
        self.reset();
        for (inputs) |in| self.vm.push(in);
        try self.run(self.quotation(&.{self.builtin(word_name)}));
        try std.testing.expectEqual(outputs.len, self.depth());
        var i = outputs.len;
        while (i > 0) {
            i -= 1;
            try std.testing.expectEqual(outputs[i], self.vm.pop());
        }
    }
};

const fx = layouts.tagFixnum;

test "interpreter pushes literals, wrapped objects and nested quotations" {
    var t = try InterpTestVM.init();
    defer t.deinit();
    const s = t.string("s");
    const inner = t.quotation(&.{fx(2)});
    const w = t.builtin("dup");
    const quot = t.quotation(&.{ fx(1), s, inner, t.wrapper(w), layouts.false_object });
    try t.run(quot);
    try std.testing.expectEqual(@as(Cell, 5), t.depth());
    try std.testing.expectEqual(layouts.false_object, t.vm.pop());
    // A wrapper pushes the wrapped word instead of executing it.
    try std.testing.expectEqual(w, t.vm.pop());
    try std.testing.expectEqual(inner, t.vm.pop());
    try std.testing.expectEqual(s, t.vm.pop());
    try std.testing.expectEqual(fx(1), t.vm.pop());
}

test "interpreter stack shufflers" {
    var t = try InterpTestVM.init();
    defer t.deinit();
    const a = fx(1);
    const b = fx(2);
    const c = fx(3);
    try t.expectStack("swap", &.{ a, b }, &.{ b, a });
    try t.expectStack("dup", &.{a}, &.{ a, a });
    try t.expectStack("drop", &.{ a, b }, &.{a});
    try t.expectStack("over", &.{ a, b }, &.{ a, b, a });
    try t.expectStack("rot", &.{ a, b, c }, &.{ b, c, a });
    try t.expectStack("-rot", &.{ a, b, c }, &.{ c, a, b });
    try t.expectStack("2dup", &.{ a, b }, &.{ a, b, a, b });
    try t.expectStack("2drop", &.{ a, b, c }, &.{a});
    try t.expectStack("3dup", &.{ a, b, c }, &.{ a, b, c, a, b, c });
    try t.expectStack("pick", &.{ a, b, c }, &.{ a, b, c, a });
    try t.expectStack("nip", &.{ a, b }, &.{b});
    try t.expectStack("dupd", &.{ a, b }, &.{ a, a, b });
    try t.expectStack("swapd", &.{ a, b, c }, &.{ b, a, c });
}

test "interpreter combinators call dip keep if and ?" {
    var t = try InterpTestVM.init();
    defer t.deinit();
    const plus = t.builtin("fixnum+");

    try t.run(t.quotation(&.{ fx(1), t.quotation(&.{fx(2)}), t.builtin("call") }));
    try std.testing.expectEqual(fx(2), t.vm.pop());
    try std.testing.expectEqual(fx(1), t.vm.pop());

    t.reset();
    try t.run(t.quotation(&.{ fx(1), fx(2), t.quotation(&.{ fx(10), plus }), t.builtin("dip") }));
    try std.testing.expectEqual(fx(2), t.vm.pop());
    try std.testing.expectEqual(fx(11), t.vm.pop());

    t.reset();
    try t.run(t.quotation(&.{ fx(5), t.quotation(&.{ fx(1), plus }), t.builtin("keep") }));
    try std.testing.expectEqual(fx(5), t.vm.pop());
    try std.testing.expectEqual(fx(6), t.vm.pop());

    const yes = t.quotation(&.{fx(1)});
    const no = t.quotation(&.{fx(2)});
    t.reset();
    try t.run(t.quotation(&.{ t.true_obj, yes, no, t.builtin("if") }));
    try std.testing.expectEqual(fx(1), t.vm.pop());
    t.reset();
    try t.run(t.quotation(&.{ layouts.false_object, yes, no, t.builtin("if") }));
    try std.testing.expectEqual(fx(2), t.vm.pop());
    // Any non-f value counts as true.
    t.reset();
    try t.run(t.quotation(&.{ fx(0), yes, no, t.builtin("if") }));
    try std.testing.expectEqual(fx(1), t.vm.pop());

    t.reset();
    try t.run(t.quotation(&.{ t.true_obj, fx(1), fx(2), t.builtin("?") }));
    try std.testing.expectEqual(fx(1), t.vm.pop());
    t.reset();
    try t.run(t.quotation(&.{ layouts.false_object, fx(1), fx(2), t.builtin("?") }));
    try std.testing.expectEqual(fx(2), t.vm.pop());
    try std.testing.expectEqual(@as(Cell, 0), t.depth());
}

test "interpreter fixnum arithmetic bit operations and comparisons" {
    var t = try InterpTestVM.init();
    defer t.deinit();
    const T = t.true_obj;
    const F = layouts.false_object;
    try t.expectStack("fixnum+", &.{ fx(3), fx(4) }, &.{fx(7)});
    try t.expectStack("fixnum+fast", &.{ fx(3), fx(4) }, &.{fx(7)});
    try t.expectStack("fixnum-", &.{ fx(3), fx(4) }, &.{fx(-1)});
    try t.expectStack("fixnum-fast", &.{ fx(-3), fx(-4) }, &.{fx(1)});
    try t.expectStack("fixnum*", &.{ fx(-3), fx(4) }, &.{fx(-12)});
    try t.expectStack("fixnum*fast", &.{ fx(6), fx(7) }, &.{fx(42)});
    try t.expectStack("fixnum-bitand", &.{ fx(0b1100), fx(0b1010) }, &.{fx(0b1000)});
    try t.expectStack("fixnum-bitor", &.{ fx(0b1100), fx(0b1010) }, &.{fx(0b1110)});
    try t.expectStack("fixnum-bitxor", &.{ fx(0b1100), fx(0b1010) }, &.{fx(0b0110)});
    try t.expectStack("fixnum-bitnot", &.{fx(0)}, &.{fx(-1)});
    try t.expectStack("fixnum-shift", &.{ fx(1), fx(4) }, &.{fx(16)});
    try t.expectStack("fixnum-shift", &.{ fx(16), fx(-2) }, &.{fx(4)});
    try t.expectStack("fixnum-shift", &.{ fx(-16), fx(-2) }, &.{fx(-4)});
    try t.expectStack("fixnum-shift", &.{ fx(-1), fx(-100) }, &.{fx(-1)});
    try t.expectStack("fixnum-shift", &.{ fx(5), fx(0) }, &.{fx(5)});
    try t.expectStack("fixnum<", &.{ fx(1), fx(2) }, &.{T});
    try t.expectStack("fixnum<", &.{ fx(2), fx(2) }, &.{F});
    try t.expectStack("fixnum<=", &.{ fx(2), fx(2) }, &.{T});
    try t.expectStack("fixnum>", &.{ fx(1), fx(2) }, &.{F});
    try t.expectStack("fixnum>", &.{ fx(3), fx(2) }, &.{T});
    try t.expectStack("fixnum>=", &.{ fx(-2), fx(-2) }, &.{T});
    try t.expectStack("fixnum>=", &.{ fx(-3), fx(-2) }, &.{F});
    try t.expectStack("both-fixnums?", &.{ fx(1), fx(2) }, &.{T});
    const s = t.string("x");
    try t.expectStack("both-fixnums?", &.{ fx(1), s }, &.{F});
    try t.expectStack("eq?", &.{ s, s }, &.{T});
    try t.expectStack("eq?", &.{ s, t.string("x") }, &.{F});
    try t.expectStack("eq?", &.{ fx(9), fx(9) }, &.{T});
}

test "interpreter tag and length" {
    var t = try InterpTestVM.init();
    defer t.deinit();
    const arr = t.vm.allotArray(3, layouts.false_object) orelse return error.OutOfMemory;
    const ba = t.vm.allotByteArray(5);
    const s = t.string("abc");
    const q = t.quotation(&.{ fx(1), fx(2) });
    try t.expectStack("tag", &.{fx(1)}, &.{fx(@intFromEnum(layouts.TypeTag.fixnum))});
    try t.expectStack("tag", &.{layouts.false_object}, &.{fx(@intFromEnum(layouts.TypeTag.f))});
    try t.expectStack("tag", &.{arr}, &.{fx(@intFromEnum(layouts.TypeTag.array))});
    try t.expectStack("tag", &.{s}, &.{fx(@intFromEnum(layouts.TypeTag.string))});
    try t.expectStack("length", &.{arr}, &.{fx(3)});
    try t.expectStack("length", &.{ba}, &.{fx(5)});
    try t.expectStack("length", &.{s}, &.{fx(3)});
    try t.expectStack("length", &.{q}, &.{fx(2)});
    try t.expectStack("length", &.{fx(1)}, &.{fx(0)});
}

test "interpreter runs word definitions and reports undefined words" {
    var t = try InterpTestVM.init();
    defer t.deinit();
    const double = t.word("double", t.quotation(&.{ t.builtin("dup"), t.builtin("fixnum+") }));
    try t.run(t.quotation(&.{ fx(21), double }));
    try std.testing.expectEqual(fx(42), t.vm.pop());

    // Words calling words.
    const quadruple = t.word("quadruple", t.quotation(&.{ double, double }));
    try t.run(t.quotation(&.{ fx(3), quadruple }));
    try std.testing.expectEqual(fx(12), t.vm.pop());

    const undefined_word = t.word("mystery", layouts.false_object);
    try std.testing.expectError(ExecutionError.UndefinedWord, t.run(t.quotation(&.{undefined_word})));
    try std.testing.expectError(ExecutionError.InvalidQuotation, t.run(fx(5)));
    try std.testing.expectError(ExecutionError.InvalidQuotation, t.run(t.string("not a quotation")));

    // Over-long quotations are rejected before execution.
    const long_arr = t.vm.allotArray(1001, fx(0)) orelse return error.OutOfMemory;
    const long_quot = t.vm.allotObject(.quotation, @sizeOf(layouts.Quotation)) orelse return error.OutOfMemory;
    const lq: *layouts.Quotation = @ptrFromInt(layouts.UNTAG(long_quot));
    lq.array = long_arr;
    lq.cached_effect = layouts.false_object;
    lq.cache_counter = layouts.false_object;
    lq.entry_point = 0;
    try std.testing.expectError(ExecutionError.InvalidQuotation, t.run(long_quot));
    try std.testing.expectEqual(@as(Cell, 0), t.depth());
}

test "interpreter public entry points call execute if dip and keep" {
    var t = try InterpTestVM.init();
    defer t.deinit();
    var interp = Interpreter.init(t.vm);
    const plus = t.builtin("fixnum+");

    t.vm.push(t.quotation(&.{fx(7)}));
    try interp.call();
    try std.testing.expectEqual(fx(7), t.vm.pop());

    t.vm.push(fx(20));
    t.vm.push(t.word("inc", t.quotation(&.{ fx(1), plus })));
    try interp.execute();
    try std.testing.expectEqual(fx(21), t.vm.pop());

    t.vm.push(layouts.false_object);
    t.vm.push(t.quotation(&.{fx(1)}));
    t.vm.push(t.quotation(&.{fx(2)}));
    try interp.ifCombinator();
    try std.testing.expectEqual(fx(2), t.vm.pop());

    t.vm.push(fx(1));
    t.vm.push(fx(2));
    t.vm.push(t.quotation(&.{ fx(10), plus }));
    try interp.dip();
    try std.testing.expectEqual(fx(2), t.vm.pop());
    try std.testing.expectEqual(fx(11), t.vm.pop());

    t.vm.push(fx(5));
    t.vm.push(t.quotation(&.{ fx(1), plus }));
    try interp.keep();
    try std.testing.expectEqual(fx(5), t.vm.pop());
    try std.testing.expectEqual(fx(6), t.vm.pop());
    try std.testing.expectEqual(@as(Cell, 0), interp.recursion_depth);
    try std.testing.expectEqual(@as(Cell, 0), t.vm.vm_asm.ctx.retainstackDepth());
}

test "runFactor interprets a startup quotation without an entry point" {
    var t = try InterpTestVM.init();
    defer t.deinit();
    // No startup quotation: nothing happens.
    try runFactor(t.vm);
    try std.testing.expectEqual(@as(Cell, 0), t.depth());

    t.vm.setSpecialObject(.startup_quot, t.quotation(&.{ fx(3), fx(4), t.builtin("fixnum*") }));
    try runFactor(t.vm);
    try std.testing.expectEqual(fx(12), t.vm.pop());
    try std.testing.expectEqual(@as(Cell, 0), t.depth());
}

test "interpreter treats a four element quotation as ordinary code unless it is a mega-cache lookup" {
    var t = try InterpTestVM.init();
    defer t.deinit();
    const arr1 = t.vm.allotArray(1, layouts.false_object) orelse return error.OutOfMemory;
    const arr2 = t.vm.allotArray(1, layouts.false_object) orelse return error.OutOfMemory;
    // Shape [ array fixnum array word ] but the word is not the lookup word.
    try t.run(t.quotation(&.{ arr1, fx(0), arr2, t.builtin("dup") }));
    try std.testing.expectEqual(@as(Cell, 4), t.depth());
    try std.testing.expectEqual(arr2, t.vm.pop());
    try std.testing.expectEqual(arr2, t.vm.pop());
    try std.testing.expectEqual(fx(0), t.vm.pop());
    try std.testing.expectEqual(arr1, t.vm.pop());
}
