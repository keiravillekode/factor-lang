// layouts.zig - Core type definitions for Factor VM
const std = @import("std");

pub const Cell = usize;
pub const Fixnum = isize;

pub fn orderCell(context: Cell, item: Cell) std.math.Order {
    return std.math.order(context, item);
}

pub const data_alignment: Cell = 16;
pub const leaf_frame_size: Cell = 16;

pub const word_size: Cell = @bitSizeOf(Cell);

// Tag system - lower 4 bits
pub const tag_mask: Cell = 15;
pub const tag_bits: Cell = 4;

pub inline fn TAG(x: Cell) Cell {
    return x & tag_mask;
}

pub inline fn UNTAG(x: Cell) Cell {
    return x & ~tag_mask;
}

pub inline fn RETAG(x: Cell, new_tag: Cell) Cell {
    return UNTAG(x) | new_tag;
}

pub const TypeTag = enum(u4) {
    fixnum = 0,
    f = 1, // false/nil
    array = 2,
    float = 3,
    quotation = 4,
    bignum = 5,
    alien = 6,
    tuple = 7,
    wrapper = 8,
    byte_array = 9,
    callstack = 10,
    string = 11,
    word = 12,
    dll = 13,
};

pub inline fn hasTag(x: Cell, type_tag: TypeTag) bool {
    return TAG(x) == @intFromEnum(type_tag);
}

pub inline fn typeTag(x: Cell) TypeTag {
    return @enumFromInt(x & tag_mask);
}

pub inline fn retag(x: Cell, type_tag: TypeTag) Cell {
    return UNTAG(x) | @intFromEnum(type_tag);
}

pub const type_count: Cell = 14;

pub fn typeHasNoPointers(type_tag: TypeTag) bool {
    return switch (type_tag) {
        .bignum, .byte_array, .float, .callstack => true,
        else => false,
    };
}

// Floating point trap flags
pub const FPTrap = struct {
    pub const invalid_operation: Cell = 1 << 0;
    pub const overflow: Cell = 1 << 1;
    pub const underflow: Cell = 1 << 2;
    pub const zero_divide: Cell = 1 << 3;
    pub const inexact: Cell = 1 << 4;
};

// The 'f' (false) object - just the tag value
pub const false_object: Cell = @intFromEnum(TypeTag.f);

pub fn isImmediate(obj: Cell) bool {
    return TAG(obj) <= @intFromEnum(TypeTag.f);
}

// Fixnum operations
pub fn untagFixnum(tagged: Cell) Fixnum {
    return @as(Fixnum, @bitCast(tagged)) >> @intCast(tag_bits);
}

// Same as untagFixnum but returns Cell (usize) - for use in sizes/indices.
// Returns 0 for invalid inputs during GC to avoid crashing on corrupted objects.
pub fn untagFixnumUnsigned(tagged: Cell) Cell {
    if (!hasTag(tagged, .fixnum)) {
        return 0;
    }
    return @bitCast(@as(Fixnum, @bitCast(tagged)) >> @intCast(tag_bits));
}

// Fast variant of untagFixnumUnsigned for hot paths outside GC.
pub fn untagFixnumFast(tagged: Cell) Cell {
    return @bitCast(@as(Fixnum, @bitCast(tagged)) >> @intCast(tag_bits));
}

pub fn tagFixnum(untagged: Fixnum) Cell {
    return (@as(Cell, @bitCast(untagged << @intCast(tag_bits)))) | @intFromEnum(TypeTag.fixnum);
}

pub fn alignCell(a: Cell, b: Cell) Cell {
    return (a + (b - 1)) & ~(b - 1);
}

pub fn alignmentFor(a: Cell, b: Cell) Cell {
    return alignCell(a, b) - a;
}

// Object header format:
// bit 0      : free?
// bit 1      : forwarding pointer?
// if not forwarding:
//   bit 2..5    : tag
//   bit 6..end  : hashcode
// if forwarding:
//   bit 2..end  : forwarding pointer
pub const Object = extern struct {
    const Self = @This();

    header: Cell,

    pub fn isFree(self: *const Object) bool {
        return (self.header & 1) == 1;
    }

    pub fn getType(self: *const Object) TypeTag {
        return @enumFromInt(@as(u4, @truncate((self.header >> 2) & tag_mask)));
    }

    pub fn initialize(self: *Object, obj_type: TypeTag) void {
        self.header = @as(Cell, @intFromEnum(obj_type)) << 2;
    }

    pub fn hashcode(self: *const Object) Cell {
        return self.header >> 6;
    }

    pub fn setHashcode(self: *Object, hc: Cell) void {
        self.header = (self.header & 0x3f) | (hc << 6);
    }

    pub fn isForwardingPointer(self: *const Object) bool {
        return (self.header & 2) == 2;
    }

    pub fn forwardingPointer(self: *const Object) *Object {
        std.debug.assert(self.isForwardingPointer());
        std.debug.assert(UNTAG(self.header) != 0);
        return @ptrFromInt(UNTAG(self.header));
    }

    pub fn forwardTo(self: *Object, pointer: *Object) void {
        self.header = @intFromPtr(pointer) | 2;
    }

    pub fn slots(self: *const Object) [*]Cell {
        return @ptrCast(@constCast(self));
    }

    // Get pointer to data after the header (for variable-sized objects)
    pub fn dataPtr(self: *const Object, comptime T: type) [*]T {
        const base: [*]u8 = @ptrCast(@constCast(self));
        return @ptrCast(@alignCast(base + @sizeOf(Object)));
    }
};

// Array object - assembly code makes assumptions about layout
pub const Array = extern struct {
    header: Cell,
    capacity: Cell, // tagged

    pub const type_number = TypeTag.array;
    pub const element_size = @sizeOf(Cell);

    pub fn data(self: *const Array) [*]Cell {
        const base: [*]u8 = @ptrCast(@constCast(self));
        return @ptrCast(@alignCast(base + @sizeOf(Array)));
    }

    pub fn getCapacity(self: *const Array) Cell {
        return untagFixnumUnsigned(self.capacity);
    }
};

pub fn arrayCapacity(array: Cell) Cell {
    std.debug.assert(hasTag(array, .array));
    const arr: *const Array = @ptrFromInt(UNTAG(array));
    return arr.getCapacity();
}

pub fn arrayNth(array: Cell, index: Cell) Cell {
    std.debug.assert(hasTag(array, .array));
    const arr: *const Array = @ptrFromInt(UNTAG(array));
    const cap = arr.getCapacity();
    std.debug.assert(index < cap);
    return arr.data()[index];
}

// Note: caller must handle write barrier if needed
pub fn setArrayNth(array: Cell, index: Cell, value: Cell) void {
    std.debug.assert(hasTag(array, .array));
    const arr: *Array = @ptrFromInt(UNTAG(array));
    const cap = arr.getCapacity();
    std.debug.assert(index < cap);
    arr.data()[index] = value;
}

// Tuple layout - extends array with special fields
// The data after TupleLayout contains pairs of (superclass, hashcode) for each echelon
pub const TupleLayout = extern struct {
    header: Cell,
    capacity: Cell, // tagged
    klass: Cell, // tagged
    size: Cell, // tagged fixnum
    echelon: Cell, // tagged fixnum

    pub fn data(self: *const TupleLayout) [*]Cell {
        const base: [*]u8 = @ptrCast(@constCast(self));
        return @ptrCast(@alignCast(base + @sizeOf(TupleLayout)));
    }

    // and layouts are fixed up during image loading, and GC updates them
    pub fn nthSuperclass(self: *const TupleLayout, echelon_idx: Cell) Cell {
        return self.data()[echelon_idx * 2];
    }

    pub fn nthHashcode(self: *const TupleLayout, echelon_idx: Cell) Cell {
        // Hashcodes are tagged fixnums, no forwarding pointer needed
        return self.data()[echelon_idx * 2 + 1];
    }
};

const bignum = @import("bignum.zig");
pub const Bignum = bignum.Bignum;

// Byte array
pub const ByteArray = extern struct {
    header: Cell,
    capacity: Cell, // tagged

    pub const type_number = TypeTag.byte_array;
    pub const element_size: Cell = 1;

    pub fn data(self: *const ByteArray) [*]u8 {
        const base: [*]u8 = @ptrCast(@constCast(self));
        return base + @sizeOf(ByteArray);
    }
};

// String object - assembly code makes assumptions about layout
pub const String = extern struct {
    header: Cell,
    length: Cell, // tagged num of chars
    aux: Cell, // tagged (auxiliary byte_array for high Unicode, or f)
    hashcode_field: Cell, // tagged (cached string hash)

    pub const type_number = TypeTag.string;

    pub fn data(self: *const String) [*]u8 {
        const base: [*]u8 = @ptrCast(@constCast(self));
        return base + @sizeOf(String);
    }

    pub fn getLength(self: *const String) usize {
        return untagFixnumUnsigned(self.length);
    }
};

pub const Word = extern struct {
    header: Cell,
    hashcode_field: Cell, // TAGGED hashcode
    name: Cell, // TAGGED word name
    vocabulary: Cell, // TAGGED word vocabulary
    def: Cell, // TAGGED definition
    props: Cell, // TAGGED property assoc
    pic_def: Cell, // TAGGED alternative entry point for direct non-tail calls
    pic_tail_def: Cell, // TAGGED alternative entry point for direct tail calls
    subprimitive: Cell, // TAGGED machine code for sub-primitive
    entry_point: Cell, // UNTAGGED entry point: jump here to execute word

    pub const type_number = TypeTag.word;

    // code_block follows this struct
};

// Wrapper object
pub const Wrapper = extern struct {
    header: Cell,
    object: Cell, // TAGGED

    pub const type_number = TypeTag.wrapper;
};

// Boxed float - assembly code makes assumptions about layout
pub const BoxedFloat = extern struct {
    header: Cell,
    n: f64,

    pub const type_number = TypeTag.float;
};

pub const Quotation = extern struct {
    header: Cell,
    array: Cell, // tagged
    cached_effect: Cell, // tagged
    cache_counter: Cell, // tagged
    entry_point: Cell, // UNTAGGED entry point; jump here to call quotation

    pub const type_number = TypeTag.quotation;

    // code_block follows after entry_point
};

// Alien object - foreign pointer wrapper
pub const Alien = extern struct {
    header: Cell,
    base: Cell, // tagged
    expired: Cell, // tagged
    displacement: Cell, // untagged
    address: Cell, // untagged

    pub const type_number = TypeTag.alien;

    pub fn updateAddress(self: *Alien) void {
        if (self.base == false_object) {
            self.address = self.displacement;
        } else {
            self.address = UNTAG(self.base) + @sizeOf(ByteArray) + self.displacement;
        }
    }
};

// DLL object - dynamic library handle
pub const Dll = extern struct {
    header: Cell,
    path: Cell, // tagged byte array holding a C string
    handle: ?*anyopaque, // OS-specific handle

    pub const type_number = TypeTag.dll;
};

// Callstack object
pub const Callstack = extern struct {
    header: Cell,
    length: Cell, // tagged

    pub const type_number = TypeTag.callstack;

    pub fn frameTopAt(self: *const Callstack, offset: Cell) Cell {
        return @intFromPtr(self) + @sizeOf(Callstack) + offset;
    }

    pub fn top(self: *const Callstack) Cell {
        return @intFromPtr(self) + @sizeOf(Callstack);
    }

    pub fn bottom(self: *const Callstack) Cell {
        return @intFromPtr(self) + @sizeOf(Callstack) + untagFixnum(self.length);
    }

    pub fn data(self: *const Callstack) [*]const Cell {
        const base: [*]const u8 = @ptrCast(self);
        return @ptrCast(@alignCast(base + @sizeOf(Callstack)));
    }
};

// Tuple object
pub const Tuple = extern struct {
    header: Cell,
    layout: Cell, // tagged layout

    pub const type_number = TypeTag.tuple;

    pub fn data(self: *const Tuple) [*]Cell {
        const base: [*]u8 = @ptrCast(@constCast(self));
        return @ptrCast(@alignCast(base + @sizeOf(Tuple)));
    }

    pub fn getLayout(self: *const Tuple) *const TupleLayout {
        // Follow forwarding pointers - layout may have moved during GC
        const layout_addr = followForwardingPointers(self.layout);
        return @ptrFromInt(layout_addr);
    }
};

// Size calculation utilities
pub fn arraySize(comptime ArrayType: type, capacity: Cell) Cell {
    return @sizeOf(ArrayType) + capacity * ArrayType.element_size;
}

pub fn stringSize(size: Cell) Cell {
    return @sizeOf(String) + size;
}

pub fn tupleCapacity(layout: *const TupleLayout) Cell {
    return untagFixnumUnsigned(layout.size);
}

pub fn tupleSize(layout: *const TupleLayout) Cell {
    return @sizeOf(Tuple) + tupleCapacity(layout) * @sizeOf(Cell);
}

pub fn stringCapacity(str: *const String) Cell {
    return untagFixnum(str.length);
}

pub const ObjectVisitInfo = struct {
    type: TypeTag,
    slot_count: Cell,
    size: Cell,
};

// Get the number of slots and total size for an allocated object.
pub fn objectVisitInfoFromAddress(obj_addr: Cell) ObjectVisitInfo {
    if (obj_addr < 0x1000) {
        return .{ .type = .fixnum, .slot_count = 0, .size = 0 };
    }

    const object_ptr: *const Object = @ptrFromInt(obj_addr);
    if (object_ptr.isFree()) {
        return .{ .type = .fixnum, .slot_count = 0, .size = 0 };
    }

    const obj_type = object_ptr.getType();

    return switch (obj_type) {
        .array => blk: {
            const arr: *const Array = @ptrCast(object_ptr);
            const capacity = arr.getCapacity();
            break :blk .{
                .type = .array,
                .slot_count = 1 + capacity,
                .size = alignCell(@sizeOf(Array) + capacity * @sizeOf(Cell), data_alignment),
            };
        },
        .tuple => blk: {
            const t: *const Tuple = @ptrCast(object_ptr);
            const layout_cell = t.layout;
            // TupleLayout has array tag (2), not tuple tag (7).
            if (hasTag(layout_cell, .array)) {
                const layout_addr = followForwardingPointers(layout_cell);
                const layout: *const TupleLayout = @ptrFromInt(layout_addr);
                const tuple_size = tupleCapacity(layout);
                break :blk .{
                    .type = .tuple,
                    .slot_count = 1 + tuple_size,
                    .size = alignCell(@sizeOf(Tuple) + tuple_size * @sizeOf(Cell), data_alignment),
                };
            }
            break :blk .{
                .type = .tuple,
                .slot_count = 1,
                .size = alignCell(@sizeOf(Tuple), data_alignment),
            };
        },
        .float => .{
            .type = .float,
            .slot_count = 0,
            .size = alignCell(@sizeOf(BoxedFloat), data_alignment),
        },
        .bignum => blk: {
            const bn: *const Bignum = @ptrCast(object_ptr);
            const capacity = untagFixnumUnsigned(bn.capacity);
            break :blk .{
                .type = .bignum,
                .slot_count = 0,
                .size = alignCell(@sizeOf(Bignum) + capacity * @sizeOf(Cell), data_alignment),
            };
        },
        .byte_array => blk: {
            const ba: *const ByteArray = @ptrCast(object_ptr);
            const capacity = untagFixnumUnsigned(ba.capacity);
            break :blk .{
                .type = .byte_array,
                .slot_count = 0,
                .size = alignCell(@sizeOf(ByteArray) + capacity, data_alignment),
            };
        },
        .callstack => blk: {
            const cs: *const Callstack = @ptrCast(object_ptr);
            const len = untagFixnumUnsigned(cs.length);
            break :blk .{
                .type = .callstack,
                .slot_count = 0,
                .size = alignCell(@sizeOf(Callstack) + len, data_alignment),
            };
        },
        .quotation => .{
            .type = .quotation,
            .slot_count = 3,
            .size = alignCell(@sizeOf(Quotation), data_alignment),
        },
        .alien => .{
            .type = .alien,
            .slot_count = 2,
            .size = alignCell(@sizeOf(Alien), data_alignment),
        },
        .wrapper => .{
            .type = .wrapper,
            .slot_count = 1,
            .size = alignCell(@sizeOf(Wrapper), data_alignment),
        },
        .string => blk: {
            const str: *const String = @ptrCast(object_ptr);
            const len = untagFixnumUnsigned(str.length);
            break :blk .{
                .type = .string,
                .slot_count = 3,
                .size = alignCell(@sizeOf(String) + len, data_alignment),
            };
        },
        .word => .{
            .type = .word,
            .slot_count = 8,
            .size = alignCell(@sizeOf(Word), data_alignment),
        },
        .dll => .{
            .type = .dll,
            .slot_count = 1,
            .size = alignCell(@sizeOf(Dll), data_alignment),
        },
        .fixnum => .{ .type = .fixnum, .slot_count = 0, .size = data_alignment },
        .f => .{ .type = .f, .slot_count = 0, .size = data_alignment },
    };
}

// Get the number of slots (cells) in an object that should be scanned by GC.
pub fn slotCount(obj: Cell) Cell {
    if (isImmediate(obj)) return 0;
    return objectVisitInfoFromAddress(UNTAG(obj)).slot_count;
}

// Like slot_count, but takes an untagged object address (reads type from header).
pub fn slotCountFromAddress(obj_addr: Cell) Cell {
    return objectVisitInfoFromAddress(obj_addr).slot_count;
}

// Array reallocation requires VM context for proper allocation and GC coordination.

// Follow forwarding pointer chain to find the actual object location.
// This is critical during GC when objects may have been moved.
pub fn followForwardingPointers(addr: Cell) Cell {
    var current = UNTAG(addr);

    // Safety check: don't dereference null/invalid pointers
    if (current < 0x1000) {
        return current;
    }

    var obj: *Object = @ptrFromInt(current);

    // Follow forwarding pointer chain (bounded to detect corruption)
    const max_hops = 16;
    var hops: u32 = 0;
    while (obj.isForwardingPointer()) : (hops += 1) {
        if (hops >= max_hops) break;
        obj = obj.forwardingPointer();
        current = @intFromPtr(obj);
    }

    return current;
}

// Tagged pointer utilities
pub fn tag(comptime T: type, value: *T) Cell {
    std.debug.assert(@intFromPtr(value) % data_alignment == 0);
    return @intFromPtr(value) | @intFromEnum(T.type_number);
}

pub fn untag(comptime T: type, value: Cell) *T {
    std.debug.assert(UNTAG(value) != 0);
    std.debug.assert(UNTAG(value) % data_alignment == 0);
    return @ptrFromInt(UNTAG(value));
}

// Specific tag functions for common types
pub fn tagBignum(bn: *Bignum) Cell {
    std.debug.assert(@intFromPtr(bn) % data_alignment == 0);
    return @intFromPtr(bn) | @intFromEnum(TypeTag.bignum);
}

pub fn tagFloat(boxed: *BoxedFloat) Cell {
    std.debug.assert(@intFromPtr(boxed) % data_alignment == 0);
    return @intFromPtr(boxed) | @intFromEnum(TypeTag.float);
}

// Verify struct layouts at compile time
comptime {
    // Ensure Object is the correct size
    std.debug.assert(@sizeOf(Object) == @sizeOf(Cell));

    // Ensure Array fields are in correct order
    std.debug.assert(@offsetOf(Array, "header") == 0);
    std.debug.assert(@offsetOf(Array, "capacity") == @sizeOf(Cell));

    // Ensure Word fields are in correct order (critical for assembly)
    std.debug.assert(@offsetOf(Word, "header") == 0 * @sizeOf(Cell));
    std.debug.assert(@offsetOf(Word, "hashcode_field") == 1 * @sizeOf(Cell));
    std.debug.assert(@offsetOf(Word, "name") == 2 * @sizeOf(Cell));
    std.debug.assert(@offsetOf(Word, "vocabulary") == 3 * @sizeOf(Cell));
    std.debug.assert(@offsetOf(Word, "def") == 4 * @sizeOf(Cell));
    std.debug.assert(@offsetOf(Word, "props") == 5 * @sizeOf(Cell));
    std.debug.assert(@offsetOf(Word, "pic_def") == 6 * @sizeOf(Cell));
    std.debug.assert(@offsetOf(Word, "pic_tail_def") == 7 * @sizeOf(Cell));
    std.debug.assert(@offsetOf(Word, "subprimitive") == 8 * @sizeOf(Cell));
    std.debug.assert(@offsetOf(Word, "entry_point") == 9 * @sizeOf(Cell));

    // Ensure Quotation fields are in correct order (critical for assembly)
    std.debug.assert(@offsetOf(Quotation, "header") == 0 * @sizeOf(Cell));
    std.debug.assert(@offsetOf(Quotation, "array") == 1 * @sizeOf(Cell));
    std.debug.assert(@offsetOf(Quotation, "cached_effect") == 2 * @sizeOf(Cell));
    std.debug.assert(@offsetOf(Quotation, "cache_counter") == 3 * @sizeOf(Cell));
    std.debug.assert(@offsetOf(Quotation, "entry_point") == 4 * @sizeOf(Cell));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const fixnum_max_test: Fixnum = (@as(Fixnum, 1) << @as(u6, @intCast(word_size - tag_bits - 1))) - 1;
const fixnum_min_test: Fixnum = -fixnum_max_test - 1;

fn testHeader(t: TypeTag) Cell {
    return @as(Cell, @intFromEnum(t)) << 2;
}

const all_type_tags = [_]TypeTag{
    .fixnum, .f, .array, .float, .quotation, .bignum, .alien, .tuple, .wrapper, .byte_array, .callstack, .string, .word, .dll,
};

test "layouts constants match the C++ VM" {
    try testing.expectEqual(@as(Cell, 16), data_alignment);
    try testing.expectEqual(@as(Cell, 15), tag_mask);
    try testing.expectEqual(@as(Cell, 4), tag_bits);
    try testing.expectEqual(@as(Cell, 64), word_size);
    try testing.expectEqual(@as(Cell, 14), type_count);
    try testing.expectEqual(@as(Cell, 1), false_object);

    // Tag numbering must match vm/layouts.hpp's enum type_tags.
    try testing.expectEqual(@as(u4, 0), @intFromEnum(TypeTag.fixnum));
    try testing.expectEqual(@as(u4, 1), @intFromEnum(TypeTag.f));
    try testing.expectEqual(@as(u4, 2), @intFromEnum(TypeTag.array));
    try testing.expectEqual(@as(u4, 3), @intFromEnum(TypeTag.float));
    try testing.expectEqual(@as(u4, 4), @intFromEnum(TypeTag.quotation));
    try testing.expectEqual(@as(u4, 5), @intFromEnum(TypeTag.bignum));
    try testing.expectEqual(@as(u4, 6), @intFromEnum(TypeTag.alien));
    try testing.expectEqual(@as(u4, 7), @intFromEnum(TypeTag.tuple));
    try testing.expectEqual(@as(u4, 8), @intFromEnum(TypeTag.wrapper));
    try testing.expectEqual(@as(u4, 9), @intFromEnum(TypeTag.byte_array));
    try testing.expectEqual(@as(u4, 10), @intFromEnum(TypeTag.callstack));
    try testing.expectEqual(@as(u4, 11), @intFromEnum(TypeTag.string));
    try testing.expectEqual(@as(u4, 12), @intFromEnum(TypeTag.word));
    try testing.expectEqual(@as(u4, 13), @intFromEnum(TypeTag.dll));
    try testing.expectEqual(all_type_tags.len, type_count);

    // type_number constants agree with the tag enum.
    try testing.expectEqual(TypeTag.array, Array.type_number);
    try testing.expectEqual(TypeTag.byte_array, ByteArray.type_number);
    try testing.expectEqual(TypeTag.string, String.type_number);
    try testing.expectEqual(TypeTag.word, Word.type_number);
    try testing.expectEqual(TypeTag.wrapper, Wrapper.type_number);
    try testing.expectEqual(TypeTag.float, BoxedFloat.type_number);
    try testing.expectEqual(TypeTag.quotation, Quotation.type_number);
    try testing.expectEqual(TypeTag.alien, Alien.type_number);
    try testing.expectEqual(TypeTag.dll, Dll.type_number);
    try testing.expectEqual(TypeTag.callstack, Callstack.type_number);
    try testing.expectEqual(TypeTag.tuple, Tuple.type_number);
    try testing.expectEqual(TypeTag.bignum, Bignum.type_number);

    // FP trap bits are distinct single bits.
    try testing.expectEqual(@as(Cell, 1), FPTrap.invalid_operation);
    try testing.expectEqual(@as(Cell, 2), FPTrap.overflow);
    try testing.expectEqual(@as(Cell, 4), FPTrap.underflow);
    try testing.expectEqual(@as(Cell, 8), FPTrap.zero_divide);
    try testing.expectEqual(@as(Cell, 16), FPTrap.inexact);
}

test "layouts struct sizes" {
    try testing.expectEqual(@as(usize, 8), @sizeOf(Object));
    try testing.expectEqual(@as(usize, 16), @sizeOf(Array));
    try testing.expectEqual(@as(usize, 16), @sizeOf(ByteArray));
    try testing.expectEqual(@as(usize, 16), @sizeOf(Bignum));
    try testing.expectEqual(@as(usize, 32), @sizeOf(String));
    try testing.expectEqual(@as(usize, 16), @sizeOf(Wrapper));
    try testing.expectEqual(@as(usize, 16), @sizeOf(BoxedFloat));
    try testing.expectEqual(@as(usize, 40), @sizeOf(Quotation));
    try testing.expectEqual(@as(usize, 40), @sizeOf(Alien));
    try testing.expectEqual(@as(usize, 24), @sizeOf(Dll));
    try testing.expectEqual(@as(usize, 16), @sizeOf(Callstack));
    try testing.expectEqual(@as(usize, 16), @sizeOf(Tuple));
    try testing.expectEqual(@as(usize, 40), @sizeOf(TupleLayout));
    try testing.expectEqual(@as(usize, 80), @sizeOf(Word));

    // Alien layout is relied on by assembly code.
    try testing.expectEqual(@as(usize, 8), @offsetOf(Alien, "base"));
    try testing.expectEqual(@as(usize, 16), @offsetOf(Alien, "expired"));
    try testing.expectEqual(@as(usize, 24), @offsetOf(Alien, "displacement"));
    try testing.expectEqual(@as(usize, 32), @offsetOf(Alien, "address"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(String, "length"));
    try testing.expectEqual(@as(usize, 16), @offsetOf(String, "aux"));
    try testing.expectEqual(@as(usize, 24), @offsetOf(String, "hashcode_field"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(Tuple, "layout"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(BoxedFloat, "n"));
}

test "layouts TAG UNTAG RETAG" {
    const base: Cell = 0x7f00_0000_1230;
    try testing.expectEqual(@as(Cell, 0), TAG(base));
    try testing.expectEqual(base, UNTAG(base));

    for (all_type_tags) |t| {
        const tagged = base | @intFromEnum(t);
        try testing.expectEqual(@as(Cell, @intFromEnum(t)), TAG(tagged));
        try testing.expectEqual(base, UNTAG(tagged));
        try testing.expect(hasTag(tagged, t));
        try testing.expectEqual(t, typeTag(tagged));
        try testing.expectEqual(tagged, retag(base, t));
        try testing.expectEqual(tagged, retag(base | 0xf, t));
        try testing.expectEqual(tagged, RETAG(base | 0xf, @intFromEnum(t)));

        // hasTag is false for every other tag
        for (all_type_tags) |other| {
            if (other != t) try testing.expect(!hasTag(tagged, other));
        }
    }

    // RETAG discards the old tag entirely
    try testing.expectEqual(@as(Cell, 0x10 | 5), RETAG(0x10 | 0xa, 5));
    try testing.expectEqual(@as(Cell, 0xffff_ffff_ffff_fff0), UNTAG(std.math.maxInt(Cell)));
    try testing.expectEqual(@as(Cell, 0xf), TAG(std.math.maxInt(Cell)));
}

test "layouts isImmediate" {
    try testing.expect(isImmediate(tagFixnum(0)));
    try testing.expect(isImmediate(tagFixnum(-1)));
    try testing.expect(isImmediate(tagFixnum(12345)));
    try testing.expect(isImmediate(false_object));
    try testing.expect(isImmediate(0x1000 | @as(Cell, @intFromEnum(TypeTag.f))));
    for (all_type_tags) |t| {
        const expect_imm = (t == .fixnum or t == .f);
        try testing.expectEqual(expect_imm, isImmediate(0x1000 | @as(Cell, @intFromEnum(t))));
    }
}

test "layouts fixnum tagging round trips" {
    const values = [_]Fixnum{ 0, 1, -1, 2, -2, 42, -42, 1 << 20, -(1 << 20), fixnum_max_test, fixnum_min_test, fixnum_max_test - 1, fixnum_min_test + 1 };
    for (values) |v| {
        const tagged = tagFixnum(v);
        try testing.expect(hasTag(tagged, .fixnum));
        try testing.expectEqual(@as(Cell, 0), TAG(tagged));
        try testing.expectEqual(v, untagFixnum(tagged));
        try testing.expectEqual(@as(Cell, @bitCast(v)), untagFixnumFast(tagged));
        try testing.expectEqual(@as(Cell, @bitCast(v)), untagFixnumUnsigned(tagged));
    }

    // The tagged representation is the value shifted by the tag bits.
    try testing.expectEqual(@as(Cell, 16), tagFixnum(1));
    try testing.expectEqual(@as(Cell, 0), tagFixnum(0));
    try testing.expectEqual(@as(Cell, 0xffff_ffff_ffff_fff0), tagFixnum(-1));
    try testing.expectEqual(@as(Cell, 0x7fff_ffff_ffff_fff0), tagFixnum(fixnum_max_test));
    try testing.expectEqual(@as(Cell, 0x8000_0000_0000_0000), tagFixnum(fixnum_min_test));

    // One past the range wraps (as implemented: the shift discards the top bits).
    try testing.expectEqual(fixnum_min_test, untagFixnum(tagFixnum(fixnum_max_test + 1)));
    try testing.expectEqual(fixnum_max_test, untagFixnum(tagFixnum(fixnum_min_test - 1)));

    // fixnum_max_test agrees with the tag width: 2^59 - 1 on 64-bit.
    try testing.expectEqual(@as(Fixnum, (1 << 59) - 1), fixnum_max_test);
}

test "layouts untagFixnumUnsigned rejects non-fixnums" {
    // Any non-fixnum tag yields 0 (defensive path used during GC).
    for (all_type_tags) |t| {
        if (t == .fixnum) continue;
        try testing.expectEqual(@as(Cell, 0), untagFixnumUnsigned(0x1230 | @as(Cell, @intFromEnum(t))));
    }
    try testing.expectEqual(@as(Cell, 0), untagFixnumUnsigned(false_object));
    // The fast variant does not check, it just shifts.
    try testing.expectEqual(@as(Cell, 0x123), untagFixnumFast(0x1230 | @as(Cell, @intFromEnum(TypeTag.array))));
    // Negative fixnums as Cell are two's complement.
    try testing.expectEqual(std.math.maxInt(Cell), untagFixnumUnsigned(tagFixnum(-1)));
}

test "layouts orderCell" {
    try testing.expectEqual(std.math.Order.lt, orderCell(1, 2));
    try testing.expectEqual(std.math.Order.eq, orderCell(7, 7));
    try testing.expectEqual(std.math.Order.gt, orderCell(9, 2));
    try testing.expectEqual(std.math.Order.lt, orderCell(0, std.math.maxInt(Cell)));
}

test "layouts alignCell and alignmentFor" {
    try testing.expectEqual(@as(Cell, 0), alignCell(0, 16));
    try testing.expectEqual(@as(Cell, 16), alignCell(1, 16));
    try testing.expectEqual(@as(Cell, 16), alignCell(15, 16));
    try testing.expectEqual(@as(Cell, 16), alignCell(16, 16));
    try testing.expectEqual(@as(Cell, 32), alignCell(17, 16));
    try testing.expectEqual(@as(Cell, 32), alignCell(31, 16));
    try testing.expectEqual(@as(Cell, 32), alignCell(32, 16));
    try testing.expectEqual(@as(Cell, 8), alignCell(5, 8));
    try testing.expectEqual(@as(Cell, 4096), alignCell(4095, 4096));
    try testing.expectEqual(@as(Cell, 8192), alignCell(4097, 4096));
    try testing.expectEqual(@as(Cell, 3), alignCell(3, 1));
    try testing.expectEqual(@as(Cell, 4), alignCell(3, 2));

    try testing.expectEqual(@as(Cell, 0), alignmentFor(0, 16));
    try testing.expectEqual(@as(Cell, 15), alignmentFor(1, 16));
    try testing.expectEqual(@as(Cell, 1), alignmentFor(15, 16));
    try testing.expectEqual(@as(Cell, 0), alignmentFor(16, 16));
    try testing.expectEqual(@as(Cell, 15), alignmentFor(17, 16));
    try testing.expectEqual(@as(Cell, 0), alignmentFor(48, 8));

    // Round trip property: alignCell(a, b) - alignmentFor(a, b) == a
    var a: Cell = 0;
    while (a < 200) : (a += 7) {
        inline for (.{ 1, 2, 4, 8, 16, 64 }) |b| {
            const r = alignCell(a, b);
            try testing.expect(r >= a);
            try testing.expect(r - a < b);
            try testing.expectEqual(@as(Cell, 0), r % b);
            try testing.expectEqual(a, r - alignmentFor(a, b));
        }
    }
}

test "layouts typeHasNoPointers" {
    // Types whose payload is raw data only.
    try testing.expect(typeHasNoPointers(.bignum));
    try testing.expect(typeHasNoPointers(.byte_array));
    try testing.expect(typeHasNoPointers(.float));
    try testing.expect(typeHasNoPointers(.callstack));

    // Types that contain tagged slots.
    try testing.expect(!typeHasNoPointers(.array));
    try testing.expect(!typeHasNoPointers(.tuple));
    try testing.expect(!typeHasNoPointers(.quotation));
    try testing.expect(!typeHasNoPointers(.alien));
    try testing.expect(!typeHasNoPointers(.wrapper));
    try testing.expect(!typeHasNoPointers(.string));
    try testing.expect(!typeHasNoPointers(.word));
    try testing.expect(!typeHasNoPointers(.dll));
    try testing.expect(!typeHasNoPointers(.fixnum));
    try testing.expect(!typeHasNoPointers(.f));

    // Cross-check: pointer-free types report zero slots in objectVisitInfo,
    // and pointer-carrying heap types report at least one.
    var buf: [8]Cell align(16) = @splat(0);
    for (all_type_tags) |t| {
        if (t == .fixnum or t == .f) continue;
        buf = @splat(0);
        buf[0] = testHeader(t);
        buf[1] = tagFixnum(0);
        const info = objectVisitInfoFromAddress(@intFromPtr(&buf));
        if (typeHasNoPointers(t)) {
            try testing.expectEqual(@as(Cell, 0), info.slot_count);
        } else {
            try testing.expect(info.slot_count >= 1);
        }
    }
}

test "layouts Object header encoding" {
    var obj: Object = .{ .header = 0xdead };
    for (all_type_tags) |t| {
        obj.initialize(t);
        try testing.expectEqual(testHeader(t), obj.header);
        try testing.expectEqual(t, obj.getType());
        try testing.expect(!obj.isFree());
        try testing.expect(!obj.isForwardingPointer());
        try testing.expectEqual(@as(Cell, 0), obj.hashcode());
    }

    obj.initialize(.tuple);
    obj.setHashcode(0x1234_5678);
    try testing.expectEqual(@as(Cell, 0x1234_5678), obj.hashcode());
    try testing.expectEqual(TypeTag.tuple, obj.getType());
    try testing.expect(!obj.isFree());
    try testing.expect(!obj.isForwardingPointer());
    try testing.expectEqual((@as(Cell, 0x1234_5678) << 6) | testHeader(.tuple), obj.header);

    // Replacing the hashcode preserves the low 6 bits.
    obj.setHashcode(1);
    try testing.expectEqual(@as(Cell, 1), obj.hashcode());
    try testing.expectEqual(TypeTag.tuple, obj.getType());

    // Largest hashcode that fits in 58 bits.
    const max_hc: Cell = (@as(Cell, 1) << 58) - 1;
    obj.setHashcode(max_hc);
    try testing.expectEqual(max_hc, obj.hashcode());
    try testing.expectEqual(TypeTag.tuple, obj.getType());

    // Free bit.
    obj.header = testHeader(.array) | 1;
    try testing.expect(obj.isFree());
    try testing.expect(!obj.isForwardingPointer());
    try testing.expectEqual(TypeTag.array, obj.getType());
}

test "layouts Object forwarding pointers" {
    var target: [2]Cell align(16) = .{ testHeader(.array), tagFixnum(0) };
    var src: Object = .{ .header = testHeader(.array) };
    try testing.expect(!src.isForwardingPointer());

    const target_obj: *Object = @ptrCast(&target);
    src.forwardTo(target_obj);
    try testing.expect(src.isForwardingPointer());
    try testing.expect(!src.isFree());
    try testing.expectEqual(@intFromPtr(target_obj) | 2, src.header);
    try testing.expectEqual(target_obj, src.forwardingPointer());
    try testing.expectEqual(@intFromPtr(target_obj), UNTAG(src.header));
}

test "layouts Object slots and dataPtr" {
    var buf: [4]Cell align(16) = .{ testHeader(.array), tagFixnum(2), 111, 222 };
    const obj: *Object = @ptrCast(&buf);
    const s = obj.slots();
    try testing.expectEqual(@intFromPtr(&buf), @intFromPtr(s));
    try testing.expectEqual(tagFixnum(2), s[1]);
    try testing.expectEqual(@as(Cell, 222), s[3]);

    const d = obj.dataPtr(Cell);
    try testing.expectEqual(@intFromPtr(&buf[1]), @intFromPtr(d));
    try testing.expectEqual(tagFixnum(2), d[0]);

    const bytes = obj.dataPtr(u8);
    try testing.expectEqual(@intFromPtr(&buf[1]), @intFromPtr(bytes));
}

test "layouts followForwardingPointers" {
    var c: [2]Cell align(16) = .{ testHeader(.array), tagFixnum(0) };
    var b: [2]Cell align(16) = .{ 0, 0 };
    var a: [2]Cell align(16) = .{ 0, 0 };
    const a_obj: *Object = @ptrCast(&a);
    const b_obj: *Object = @ptrCast(&b);
    const c_obj: *Object = @ptrCast(&c);

    // No forwarding: identity, stripping the tag.
    try testing.expectEqual(@intFromPtr(c_obj), followForwardingPointers(@intFromPtr(c_obj) | @intFromEnum(TypeTag.array)));
    try testing.expectEqual(@intFromPtr(c_obj), followForwardingPointers(@intFromPtr(c_obj)));

    // Chain a -> b -> c.
    b_obj.forwardTo(c_obj);
    a_obj.forwardTo(b_obj);
    try testing.expectEqual(@intFromPtr(c_obj), followForwardingPointers(@intFromPtr(a_obj) | @intFromEnum(TypeTag.tuple)));
    try testing.expectEqual(@intFromPtr(c_obj), followForwardingPointers(@intFromPtr(b_obj)));

    // Small addresses are returned untouched (never dereferenced).
    try testing.expectEqual(@as(Cell, 0), followForwardingPointers(0));
    try testing.expectEqual(@as(Cell, 0), followForwardingPointers(false_object));
    try testing.expectEqual(@as(Cell, 0xff0), followForwardingPointers(0xff5));

    // A cycle terminates because of the hop bound and lands on a chain member.
    b_obj.forwardTo(a_obj);
    const r = followForwardingPointers(@intFromPtr(a_obj));
    try testing.expect(r == @intFromPtr(a_obj) or r == @intFromPtr(b_obj));
}

test "layouts generic tag and untag" {
    var arr: [2]Cell align(16) = .{ testHeader(.array), tagFixnum(0) };
    const arr_ptr: *Array = @ptrCast(&arr);
    const tagged = tag(Array, arr_ptr);
    try testing.expect(hasTag(tagged, .array));
    try testing.expectEqual(@intFromPtr(arr_ptr), UNTAG(tagged));
    try testing.expectEqual(arr_ptr, untag(Array, tagged));

    var w: [2]Cell align(16) = .{ testHeader(.wrapper), tagFixnum(5) };
    const w_ptr: *Wrapper = @ptrCast(&w);
    try testing.expect(hasTag(tag(Wrapper, w_ptr), .wrapper));
    try testing.expectEqual(w_ptr, untag(Wrapper, tag(Wrapper, w_ptr)));

    var f: [2]Cell align(16) = .{ testHeader(.float), 0 };
    const f_ptr: *BoxedFloat = @ptrCast(&f);
    try testing.expectEqual(@intFromPtr(f_ptr) | 3, tagFloat(f_ptr));
    try testing.expectEqual(tag(BoxedFloat, f_ptr), tagFloat(f_ptr));

    var bn: [4]Cell align(16) = .{ testHeader(.bignum), tagFixnum(1), 0, 0 };
    const bn_ptr: *Bignum = @ptrCast(&bn);
    try testing.expectEqual(@intFromPtr(bn_ptr) | 5, tagBignum(bn_ptr));
    try testing.expectEqual(tag(Bignum, bn_ptr), tagBignum(bn_ptr));

    // untag ignores whatever tag bits are present.
    try testing.expectEqual(arr_ptr, untag(Array, @intFromPtr(arr_ptr) | 0xf));
}

test "layouts Array accessors" {
    var buf: [6]Cell align(16) = .{ testHeader(.array), tagFixnum(3), tagFixnum(10), tagFixnum(20), tagFixnum(30), 0xdead };
    const arr: *Array = @ptrCast(&buf);
    try testing.expectEqual(@as(Cell, 3), arr.getCapacity());
    try testing.expectEqual(@intFromPtr(&buf[2]), @intFromPtr(arr.data()));
    try testing.expectEqual(tagFixnum(30), arr.data()[2]);

    const tagged = tag(Array, arr);
    try testing.expectEqual(@as(Cell, 3), arrayCapacity(tagged));
    try testing.expectEqual(tagFixnum(10), arrayNth(tagged, 0));
    try testing.expectEqual(tagFixnum(20), arrayNth(tagged, 1));
    try testing.expectEqual(tagFixnum(30), arrayNth(tagged, 2));

    setArrayNth(tagged, 1, tagFixnum(-7));
    try testing.expectEqual(tagFixnum(-7), arrayNth(tagged, 1));
    try testing.expectEqual(tagFixnum(-7), buf[3]);
    // Neighbours untouched.
    try testing.expectEqual(tagFixnum(10), buf[2]);
    try testing.expectEqual(tagFixnum(30), buf[4]);
    try testing.expectEqual(@as(Cell, 0xdead), buf[5]);

    // Capacity is decoded from a tagged fixnum; a corrupt tag yields 0.
    var bad: [2]Cell align(16) = .{ testHeader(.array), 0x30 | @as(Cell, @intFromEnum(TypeTag.array)) };
    const bad_arr: *Array = @ptrCast(&bad);
    try testing.expectEqual(@as(Cell, 0), bad_arr.getCapacity());
}

test "layouts size calculations" {
    try testing.expectEqual(@as(Cell, 16), arraySize(Array, 0));
    try testing.expectEqual(@as(Cell, 24), arraySize(Array, 1));
    try testing.expectEqual(@as(Cell, 16 + 8 * 100), arraySize(Array, 100));
    try testing.expectEqual(@as(Cell, 16), arraySize(ByteArray, 0));
    try testing.expectEqual(@as(Cell, 17), arraySize(ByteArray, 1));
    try testing.expectEqual(@as(Cell, 16 + 33), arraySize(ByteArray, 33));
    try testing.expectEqual(@as(Cell, 16 + 8 * 4), arraySize(Bignum, 4));

    try testing.expectEqual(@as(Cell, 32), stringSize(0));
    try testing.expectEqual(@as(Cell, 32 + 5), stringSize(5));

    var str: String = .{ .header = testHeader(.string), .length = tagFixnum(11), .aux = false_object, .hashcode_field = tagFixnum(0) };
    // NOTE: stringCapacity() is never referenced by the VM and does not type-check
    // (returns isize where Cell is expected), so it is not exercised here.
    try testing.expectEqual(@as(usize, 11), str.getLength());
    try testing.expectEqual(@intFromPtr(&str) + 32, @intFromPtr(str.data()));

    var layout: TupleLayout = .{ .header = testHeader(.array), .capacity = tagFixnum(4), .klass = false_object, .size = tagFixnum(3), .echelon = tagFixnum(1) };
    try testing.expectEqual(@as(Cell, 3), tupleCapacity(&layout));
    try testing.expectEqual(@as(Cell, 16 + 3 * 8), tupleSize(&layout));
    layout.size = tagFixnum(0);
    try testing.expectEqual(@as(Cell, 0), tupleCapacity(&layout));
    try testing.expectEqual(@as(Cell, 16), tupleSize(&layout));
}

test "layouts ByteArray data" {
    var buf: [4]Cell align(16) = .{ testHeader(.byte_array), tagFixnum(16), 0, 0 };
    const ba: *ByteArray = @ptrCast(&buf);
    try testing.expectEqual(@intFromPtr(&buf[2]), @intFromPtr(ba.data()));
    ba.data()[0] = 0xaa;
    ba.data()[15] = 0xbb;
    try testing.expectEqual(@as(Cell, 0xaa), buf[2] & 0xff);
    try testing.expectEqual(@as(Cell, 0xbb), buf[3] >> 56);
}

test "layouts TupleLayout and Tuple" {
    // Layout: header, capacity, klass, size, echelon, then (superclass, hashcode) pairs.
    var layout_buf: [9]Cell align(16) = .{
        testHeader(.array),
        tagFixnum(7),
        0x1000 | @as(Cell, @intFromEnum(TypeTag.word)), // klass
        tagFixnum(2), // size: 2 slots
        tagFixnum(1), // echelon
        0x2000 | @as(Cell, @intFromEnum(TypeTag.word)), // superclass 0
        tagFixnum(100), // hashcode 0
        0x3000 | @as(Cell, @intFromEnum(TypeTag.word)), // superclass 1
        tagFixnum(200), // hashcode 1
    };
    const layout: *TupleLayout = @ptrCast(&layout_buf);
    try testing.expectEqual(@intFromPtr(&layout_buf[5]), @intFromPtr(layout.data()));
    try testing.expectEqual(@as(Cell, 0x2000 | 12), layout.nthSuperclass(0));
    try testing.expectEqual(tagFixnum(100), layout.nthHashcode(0));
    try testing.expectEqual(@as(Cell, 0x3000 | 12), layout.nthSuperclass(1));
    try testing.expectEqual(tagFixnum(200), layout.nthHashcode(1));

    var tuple_buf: [4]Cell align(16) = .{ testHeader(.tuple), tag(Array, @ptrCast(layout)), tagFixnum(1), tagFixnum(2) };
    const t: *Tuple = @ptrCast(&tuple_buf);
    try testing.expectEqual(@intFromPtr(&tuple_buf[2]), @intFromPtr(t.data()));
    try testing.expectEqual(tagFixnum(2), t.data()[1]);
    try testing.expectEqual(@as(*const TupleLayout, layout), t.getLayout());

    // getLayout follows a forwarding pointer left by a moving GC.
    var moved_layout_buf: [9]Cell align(16) = layout_buf;
    const moved_layout: *TupleLayout = @ptrCast(&moved_layout_buf);
    const old_obj: *Object = @ptrCast(layout);
    old_obj.forwardTo(@ptrCast(moved_layout));
    try testing.expectEqual(@as(*const TupleLayout, moved_layout), t.getLayout());
    try testing.expectEqual(@as(Cell, 2), tupleCapacity(t.getLayout()));
}

test "layouts Callstack accessors" {
    var buf: [6]Cell align(16) = .{ testHeader(.callstack), tagFixnum(32), 1, 2, 3, 4 };
    const cs: *Callstack = @ptrCast(&buf);
    const base = @intFromPtr(&buf);
    try testing.expectEqual(base + 16, cs.top());
    // NOTE: Callstack.bottom() is never referenced by the VM and does not type-check
    // (adds isize to usize), so it is not exercised here.
    try testing.expectEqual(base + 16, cs.frameTopAt(0));
    try testing.expectEqual(base + 16 + 8, cs.frameTopAt(8));
    try testing.expectEqual(base + 16 + 32, cs.frameTopAt(32));
    try testing.expectEqual(@intFromPtr(&buf[2]), @intFromPtr(cs.data()));
    try testing.expectEqual(@as(Cell, 1), cs.data()[0]);
    try testing.expectEqual(@as(Cell, 4), cs.data()[3]);

    // Empty callstack: frame top at the full length equals top.
    buf[1] = tagFixnum(0);
    try testing.expectEqual(cs.top(), cs.frameTopAt(untagFixnumUnsigned(buf[1])));
}

test "layouts Alien updateAddress" {
    var alien: Alien = .{ .header = testHeader(.alien), .base = false_object, .expired = false_object, .displacement = 0x1234, .address = 0 };
    alien.updateAddress();
    try testing.expectEqual(@as(Cell, 0x1234), alien.address);

    alien.displacement = 0;
    alien.updateAddress();
    try testing.expectEqual(@as(Cell, 0), alien.address);

    // Displaced alien over a byte array: address points into the payload.
    var ba: [4]Cell align(16) = .{ testHeader(.byte_array), tagFixnum(16), 0, 0 };
    const ba_ptr: *ByteArray = @ptrCast(&ba);
    alien.base = tag(ByteArray, ba_ptr);
    alien.displacement = 3;
    alien.updateAddress();
    try testing.expectEqual(@intFromPtr(ba_ptr.data()) + 3, alien.address);
    try testing.expectEqual(@intFromPtr(&ba) + 16 + 3, alien.address);

    // Base object with the tag bits set in the base cell is untagged first.
    alien.displacement = 0;
    alien.updateAddress();
    try testing.expectEqual(@intFromPtr(&ba[2]), alien.address);
}

test "layouts objectVisitInfoFromAddress per type" {
    // Small/null addresses and free objects are reported as empty.
    try testing.expectEqual(ObjectVisitInfo{ .type = .fixnum, .slot_count = 0, .size = 0 }, objectVisitInfoFromAddress(0));
    try testing.expectEqual(ObjectVisitInfo{ .type = .fixnum, .slot_count = 0, .size = 0 }, objectVisitInfoFromAddress(0xfff));

    var free_buf: [2]Cell align(16) = .{ testHeader(.array) | 1, tagFixnum(100) };
    try testing.expectEqual(ObjectVisitInfo{ .type = .fixnum, .slot_count = 0, .size = 0 }, objectVisitInfoFromAddress(@intFromPtr(&free_buf)));

    // array: capacity 3 -> header + 4 cells = 40 -> aligned 48
    var arr: [6]Cell align(16) = .{ testHeader(.array), tagFixnum(3), 0, 0, 0, 0 };
    try testing.expectEqual(ObjectVisitInfo{ .type = .array, .slot_count = 4, .size = 48 }, objectVisitInfoFromAddress(@intFromPtr(&arr)));
    arr[1] = tagFixnum(0);
    try testing.expectEqual(ObjectVisitInfo{ .type = .array, .slot_count = 1, .size = 16 }, objectVisitInfoFromAddress(@intFromPtr(&arr)));
    arr[1] = tagFixnum(2);
    try testing.expectEqual(ObjectVisitInfo{ .type = .array, .slot_count = 3, .size = 32 }, objectVisitInfoFromAddress(@intFromPtr(&arr)));

    // float: no slots, 16 bytes
    var flt: [2]Cell align(16) = .{ testHeader(.float), 0 };
    try testing.expectEqual(ObjectVisitInfo{ .type = .float, .slot_count = 0, .size = 16 }, objectVisitInfoFromAddress(@intFromPtr(&flt)));

    // bignum: capacity = digits + sign slot; capacity 3 -> 16 + 24 = 40 -> 48
    var bn: [6]Cell align(16) = .{ testHeader(.bignum), tagFixnum(3), 0, 0, 0, 0 };
    try testing.expectEqual(ObjectVisitInfo{ .type = .bignum, .slot_count = 0, .size = 48 }, objectVisitInfoFromAddress(@intFromPtr(&bn)));
    bn[1] = tagFixnum(1);
    try testing.expectEqual(ObjectVisitInfo{ .type = .bignum, .slot_count = 0, .size = 32 }, objectVisitInfoFromAddress(@intFromPtr(&bn)));

    // byte_array: capacity in bytes; 17 bytes -> 33 -> 48
    var ba: [6]Cell align(16) = .{ testHeader(.byte_array), tagFixnum(17), 0, 0, 0, 0 };
    try testing.expectEqual(ObjectVisitInfo{ .type = .byte_array, .slot_count = 0, .size = 48 }, objectVisitInfoFromAddress(@intFromPtr(&ba)));
    ba[1] = tagFixnum(16);
    try testing.expectEqual(ObjectVisitInfo{ .type = .byte_array, .slot_count = 0, .size = 32 }, objectVisitInfoFromAddress(@intFromPtr(&ba)));
    ba[1] = tagFixnum(0);
    try testing.expectEqual(ObjectVisitInfo{ .type = .byte_array, .slot_count = 0, .size = 16 }, objectVisitInfoFromAddress(@intFromPtr(&ba)));

    // callstack: length in bytes; 24 -> 40 -> 48
    var cs: [6]Cell align(16) = .{ testHeader(.callstack), tagFixnum(24), 0, 0, 0, 0 };
    try testing.expectEqual(ObjectVisitInfo{ .type = .callstack, .slot_count = 0, .size = 48 }, objectVisitInfoFromAddress(@intFromPtr(&cs)));

    // quotation: 3 slots (array, cached_effect, cache_counter), 40 -> 48
    var q: [6]Cell align(16) = .{ testHeader(.quotation), 0, 0, 0, 0, 0 };
    try testing.expectEqual(ObjectVisitInfo{ .type = .quotation, .slot_count = 3, .size = 48 }, objectVisitInfoFromAddress(@intFromPtr(&q)));

    // alien: 2 slots (base, expired), 40 -> 48
    var al: [6]Cell align(16) = .{ testHeader(.alien), 0, 0, 0, 0, 0 };
    try testing.expectEqual(ObjectVisitInfo{ .type = .alien, .slot_count = 2, .size = 48 }, objectVisitInfoFromAddress(@intFromPtr(&al)));

    // wrapper: 1 slot, 16
    var w: [2]Cell align(16) = .{ testHeader(.wrapper), 0 };
    try testing.expectEqual(ObjectVisitInfo{ .type = .wrapper, .slot_count = 1, .size = 16 }, objectVisitInfoFromAddress(@intFromPtr(&w)));

    // string: 3 slots (length, aux, hashcode); 5 chars -> 37 -> 48
    var s: [6]Cell align(16) = .{ testHeader(.string), tagFixnum(5), false_object, tagFixnum(0), 0, 0 };
    try testing.expectEqual(ObjectVisitInfo{ .type = .string, .slot_count = 3, .size = 48 }, objectVisitInfoFromAddress(@intFromPtr(&s)));
    s[1] = tagFixnum(0);
    try testing.expectEqual(ObjectVisitInfo{ .type = .string, .slot_count = 3, .size = 32 }, objectVisitInfoFromAddress(@intFromPtr(&s)));

    // word: 8 slots, 80
    var word: [10]Cell align(16) = @splat(0);
    word[0] = testHeader(.word);
    try testing.expectEqual(ObjectVisitInfo{ .type = .word, .slot_count = 8, .size = 80 }, objectVisitInfoFromAddress(@intFromPtr(&word)));

    // dll: 1 slot, 24 -> 32
    var dll: [4]Cell align(16) = .{ testHeader(.dll), 0, 0, 0 };
    try testing.expectEqual(ObjectVisitInfo{ .type = .dll, .slot_count = 1, .size = 32 }, objectVisitInfoFromAddress(@intFromPtr(&dll)));

    // Headers claiming immediate types report one alignment unit and no slots.
    var imm: [2]Cell align(16) = .{ testHeader(.fixnum), 0 };
    try testing.expectEqual(ObjectVisitInfo{ .type = .fixnum, .slot_count = 0, .size = 16 }, objectVisitInfoFromAddress(@intFromPtr(&imm)));
    imm[0] = testHeader(.f);
    try testing.expectEqual(ObjectVisitInfo{ .type = .f, .slot_count = 0, .size = 16 }, objectVisitInfoFromAddress(@intFromPtr(&imm)));

    // Hashcode bits in the header do not affect the result.
    arr[0] = testHeader(.array) | (@as(Cell, 0xabcdef) << 6);
    try testing.expectEqual(ObjectVisitInfo{ .type = .array, .slot_count = 3, .size = 32 }, objectVisitInfoFromAddress(@intFromPtr(&arr)));
}

test "layouts objectVisitInfoFromAddress tuple" {
    var layout_buf: [7]Cell align(16) = .{ testHeader(.array), tagFixnum(5), false_object, tagFixnum(3), tagFixnum(0), false_object, tagFixnum(0) };
    const layout: *TupleLayout = @ptrCast(&layout_buf);

    // 3 slots + layout slot = 4 slots; 16 + 24 = 40 -> 48
    var t: [6]Cell align(16) = .{ testHeader(.tuple), tag(Array, @ptrCast(layout)), 0, 0, 0, 0 };
    try testing.expectEqual(ObjectVisitInfo{ .type = .tuple, .slot_count = 4, .size = 48 }, objectVisitInfoFromAddress(@intFromPtr(&t)));

    // Layout moved during GC: follow the forwarding pointer.
    var moved_buf: [7]Cell align(16) = layout_buf;
    moved_buf[3] = tagFixnum(1);
    const old: *Object = @ptrCast(layout);
    old.forwardTo(@ptrCast(&moved_buf));
    try testing.expectEqual(ObjectVisitInfo{ .type = .tuple, .slot_count = 2, .size = 32 }, objectVisitInfoFromAddress(@intFromPtr(&t)));

    // A tuple whose layout slot is not an array (e.g. uninitialized) counts only the layout slot.
    t[1] = false_object;
    try testing.expectEqual(ObjectVisitInfo{ .type = .tuple, .slot_count = 1, .size = 16 }, objectVisitInfoFromAddress(@intFromPtr(&t)));
}

test "layouts slotCount and slotCountFromAddress" {
    try testing.expectEqual(@as(Cell, 0), slotCount(tagFixnum(99)));
    try testing.expectEqual(@as(Cell, 0), slotCount(tagFixnum(-1)));
    try testing.expectEqual(@as(Cell, 0), slotCount(false_object));

    var arr: [4]Cell align(16) = .{ testHeader(.array), tagFixnum(2), 0, 0 };
    const arr_ptr: *Array = @ptrCast(&arr);
    try testing.expectEqual(@as(Cell, 3), slotCount(tag(Array, arr_ptr)));
    try testing.expectEqual(@as(Cell, 3), slotCountFromAddress(@intFromPtr(&arr)));

    var q: [6]Cell align(16) = .{ testHeader(.quotation), 0, 0, 0, 0, 0 };
    try testing.expectEqual(@as(Cell, 3), slotCount(@intFromPtr(&q) | @intFromEnum(TypeTag.quotation)));
    try testing.expectEqual(@as(Cell, 3), slotCountFromAddress(@intFromPtr(&q)));

    var ba: [4]Cell align(16) = .{ testHeader(.byte_array), tagFixnum(8), 0, 0 };
    try testing.expectEqual(@as(Cell, 0), slotCount(@intFromPtr(&ba) | @intFromEnum(TypeTag.byte_array)));

    var w: [2]Cell align(16) = .{ testHeader(.wrapper), tagFixnum(1) };
    try testing.expectEqual(@as(Cell, 1), slotCount(@intFromPtr(&w) | @intFromEnum(TypeTag.wrapper)));

    var word: [10]Cell align(16) = @splat(0);
    word[0] = testHeader(.word);
    try testing.expectEqual(@as(Cell, 8), slotCountFromAddress(@intFromPtr(&word)));

    // slotCount reads the type from the header, not from the pointer tag.
    try testing.expectEqual(@as(Cell, 3), slotCount(@intFromPtr(&arr) | @intFromEnum(TypeTag.tuple)));
}
