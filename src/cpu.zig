const std = @import("std");
const builtin = @import("builtin");

pub const Arch = enum {
    x86,
    x86_64,
    aarch64,
    unsupported,

    pub fn current() Arch {
        return switch (builtin.cpu.arch) {
            .x86 => .x86,
            .x86_64 => .x86_64,
            .aarch64 => .aarch64,
            else => .unsupported,
        };
    }

    /// True for any x86 family (32-bit or 64-bit).
    pub fn isX86Family(arch: Arch) bool {
        return arch == .x86 or arch == .x86_64;
    }
};

pub const X86Instruction = struct {
    pub const CALL_OPCODE: u8 = 0xe8;
    pub const JMP_OPCODE: u8 = 0xe9;

    pub fn encodeCall(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), rel_offset: i32) !void {
        try buffer.append(allocator, CALL_OPCODE);
        const bytes: [4]u8 = @bitCast(std.mem.nativeTo(i32, rel_offset, .little));
        try buffer.appendSlice(allocator, &bytes);
    }

    pub fn encodeJump(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), rel_offset: i32) !void {
        try buffer.append(allocator, JMP_OPCODE);
        const bytes: [4]u8 = @bitCast(std.mem.nativeTo(i32, rel_offset, .little));
        try buffer.appendSlice(allocator, &bytes);
    }
};

pub const ARM64Instruction = struct {
    pub const JMP_OPCODE: u32 = 0xd61f0120; // BR X9

    fn emitU32(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), value: u32) !void {
        const bytes: [4]u8 = @bitCast(std.mem.nativeTo(u32, value, .little));
        try buffer.appendSlice(allocator, &bytes);
    }

    pub fn encodeCall(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), offset: i32) !void {
        // BL format: 1 | 00101 | imm26
        const imm26: u32 = @bitCast(@as(i32, @divExact(offset, 4)) & 0x03ffffff);
        const insn: u32 = (0b1 << 31) | (0b00101 << 26) | imm26;
        try emitU32(allocator, buffer, insn);
    }

    pub fn encodeJump(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), offset: i32) !void {
        // B format: 0 | 00101 | imm26
        const imm26: u32 = @bitCast(@as(i32, @divExact(offset, 4)) & 0x03ffffff);
        const insn: u32 = (0b0 << 31) | (0b00101 << 26) | imm26;
        try emitU32(allocator, buffer, insn);
    }
};

// --- Tests ---

const testing = std.testing;

test "Arch.current matches the build target" {
    const arch = Arch.current();
    switch (builtin.cpu.arch) {
        .x86 => try testing.expectEqual(Arch.x86, arch),
        .x86_64 => try testing.expectEqual(Arch.x86_64, arch),
        .aarch64 => try testing.expectEqual(Arch.aarch64, arch),
        else => try testing.expectEqual(Arch.unsupported, arch),
    }
    try testing.expect(Arch.x86.isX86Family());
    try testing.expect(Arch.x86_64.isX86Family());
    try testing.expect(!Arch.aarch64.isX86Family());
    try testing.expect(!Arch.unsupported.isX86Family());
}

test "x86 call and jump encodings are opcode plus little-endian rel32" {
    const allocator = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try X86Instruction.encodeCall(allocator, &buf, 0x10);
    try testing.expectEqualSlices(u8, &.{ 0xE8, 0x10, 0x00, 0x00, 0x00 }, buf.items);

    buf.clearRetainingCapacity();
    try X86Instruction.encodeJump(allocator, &buf, -6);
    try testing.expectEqualSlices(u8, &.{ 0xE9, 0xFA, 0xFF, 0xFF, 0xFF }, buf.items);

    buf.clearRetainingCapacity();
    try X86Instruction.encodeCall(allocator, &buf, std.math.minInt(i32));
    try X86Instruction.encodeJump(allocator, &buf, std.math.maxInt(i32));
    try testing.expectEqualSlices(u8, &.{ 0xE8, 0x00, 0x00, 0x00, 0x80, 0xE9, 0xFF, 0xFF, 0xFF, 0x7F }, buf.items);
}

test "arm64 call and jump encodings scale the offset into imm26" {
    const allocator = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    // BL +8: imm26 = 2.
    try ARM64Instruction.encodeCall(allocator, &buf, 8);
    try testing.expectEqualSlices(u8, &.{ 0x02, 0x00, 0x00, 0x94 }, buf.items);

    // B -4: imm26 = -1, all 26 bits set.
    buf.clearRetainingCapacity();
    try ARM64Instruction.encodeJump(allocator, &buf, -4);
    try testing.expectEqualSlices(u8, &.{ 0xFF, 0xFF, 0xFF, 0x17 }, buf.items);

    // B +0 and BL at the +-128MB limits.
    buf.clearRetainingCapacity();
    try ARM64Instruction.encodeJump(allocator, &buf, 0);
    try ARM64Instruction.encodeCall(allocator, &buf, 0x7FFFFFC);
    try ARM64Instruction.encodeCall(allocator, &buf, -0x8000000);
    try testing.expectEqualSlices(u8, &.{
        0x00, 0x00, 0x00, 0x14,
        0xFF, 0xFF, 0xFF, 0x95,
        0x00, 0x00, 0x00, 0x96,
    }, buf.items);
    try testing.expectEqual(@as(u32, 0xD61F0120), ARM64Instruction.JMP_OPCODE);
}
