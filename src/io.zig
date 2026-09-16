const std = @import("std");
const builtin = @import("builtin");

const layouts = @import("layouts.zig");
const objects = @import("objects.zig");
const vm_mod = @import("vm.zig");

const Cell = layouts.Cell;

// C library function declarations
extern "c" fn fgetc(stream: *std.c.FILE) c_int;
extern "c" fn fputc(c: c_int, stream: *std.c.FILE) c_int;
extern "c" fn ftell(stream: *std.c.FILE) c_long;
extern "c" fn fflush(stream: *std.c.FILE) c_int;
extern "c" fn feof(stream: *std.c.FILE) c_int;
extern "c" fn clearerr(stream: *std.c.FILE) void;
extern "c" fn fseek(stream: *std.c.FILE, offset: c_long, whence: c_int) c_int;

// C constants
const EOF: c_int = -1;

// Error type for I/O operations
pub const IOError = error{
    ReadError,
    WriteError,
    PipeError,
    FcntlError,
    CloseError,
    OpenError,
    SeekError,
    FlushError,
    EINTR,
    EAGAIN,
    UnexpectedEOF,
};

// C constants for fcntl/errno
const EINTR = @intFromEnum(std.posix.E.INTR);
const EAGAIN = @intFromEnum(std.posix.E.AGAIN);
const F_GETFD: c_int = 1;
const F_SETFD: c_int = 2;
const F_GETFL: c_int = 3;
const F_SETFL: c_int = 4;
const FD_CLOEXEC: c_int = 1;
const O_NONBLOCK_C: c_int = if (builtin.os.tag == .macos) 0x0004 else 0x800;

// Create a pipe pair with close-on-exec flags set
// Returns [read_fd, write_fd]
fn makePipe() ![2]i32 {
    var filedes: [2]c_int = undefined;
    if (std.c.pipe(&filedes) < 0) {
        return error.PipeError;
    }

    const read_fd = filedes[0];
    const write_fd = filedes[1];

    // Set close-on-exec on both ends
    if (std.c.fcntl(read_fd, F_SETFD, FD_CLOEXEC) < 0) {
        _ = std.c.close(read_fd);
        _ = std.c.close(write_fd);
        return error.FcntlError;
    }
    if (std.c.fcntl(write_fd, F_SETFD, FD_CLOEXEC) < 0) {
        _ = std.c.close(read_fd);
        _ = std.c.close(write_fd);
        return error.FcntlError;
    }

    return .{ read_fd, write_fd };
}

// Set file descriptor to non-blocking mode
fn setNonblocking(fd: i32) !void {
    const flags = std.c.fcntl(fd, F_GETFL);
    if (flags < 0) return error.FcntlError;
    if (std.c.fcntl(fd, F_SETFL, flags | O_NONBLOCK_C) < 0) return error.FcntlError;
}

// Initialize signal pipe for async signal delivery
// This creates a pipe that signal handlers can write to, and Factor's
// event loop can poll/select on to receive async signals safely
pub fn initSignalPipe(vm: *vm_mod.FactorVM) !void {
    const fds = try makePipe();
    vm.signal_pipe_input = fds[0];
    vm.signal_pipe_output = fds[1];

    // Make output end non-blocking so signal handlers don't block
    try setNonblocking(vm.signal_pipe_output);

    // Store input pipe fd in special objects so Factor code can poll it
    vm.setSpecialObject(objects.SpecialObject.signal_pipe, layouts.tagFixnum(vm.signal_pipe_input));
}

// Clean up signal pipe
pub fn deinitSignalPipe(vm: *vm_mod.FactorVM) void {
    if (vm.signal_pipe_input != -1) {
        _ = std.c.close(vm.signal_pipe_input);
        vm.signal_pipe_input = -1;
    }
    if (vm.signal_pipe_output != -1) {
        _ = std.c.close(vm.signal_pipe_output);
        vm.signal_pipe_output = -1;
    }
}

// Safe fopen - retries on EINTR
pub fn safeFopen(path: [*:0]const u8, mode: [*:0]const u8) !*std.c.FILE {
    while (true) {
        const file = std.c.fopen(path, mode);
        if (file) |f| {
            return f;
        }

        // Check errno
        const err = std.c._errno().*;
        if (err == @intFromEnum(std.posix.E.INTR)) {
            continue; // Retry on EINTR
        }

        return error.OpenError;
    }
}

// Safe fclose - only closes once, tolerates EINTR
pub fn safeFclose(file: *std.c.FILE) !void {
    const result = std.c.fclose(file);
    if (result != 0) {
        const err = std.c._errno().*;
        if (err != @intFromEnum(std.posix.E.INTR)) {
            return error.CloseError;
        }
    }
}

// Safe fgetc - retries on EINTR
pub fn safeFgetc(file: *std.c.FILE) !i32 {
    while (true) {
        const c = fgetc(file);
        if (c == EOF) {
            if (feof(file) != 0) {
                return EOF;
            }

            const err = std.c._errno().*;
            if (err != @intFromEnum(std.posix.E.INTR)) {
                return error.ReadError;
            }
            // Retry on EINTR
            continue;
        }
        return c;
    }
}

// Safe fread - retries on EINTR until all items read
pub fn safeFread(ptr: *anyopaque, size: usize, nitems: usize, stream: *std.c.FILE) !usize {
    var items_read: usize = 0;

    while (items_read < nitems) {
        const items_remaining = nitems - items_read;
        const offset = items_read * size;
        const dest: [*]u8 = @ptrCast(ptr);

        const ret = std.c.fread(dest + offset, size, items_remaining, stream);
        if (ret == 0) {
            if (feof(stream) != 0) {
                return items_read;
            }

            const err = std.c._errno().*;
            if (err != @intFromEnum(std.posix.E.INTR)) {
                return error.ReadError;
            }
            // Retry on EINTR
            continue;
        }
        items_read += ret;
    }

    return items_read;
}

// Safe fputc - retries on EINTR
pub fn safeFputc(c: i32, file: *std.c.FILE) !void {
    while (true) {
        const result = fputc(c, file);
        if (result != EOF) {
            return;
        }

        const err = std.c._errno().*;
        if (err != @intFromEnum(std.posix.E.INTR)) {
            return error.WriteError;
        }
        // Retry on EINTR
    }
}

// Safe fwrite - retries on EINTR until all items written
pub fn safeFwrite(ptr: *const anyopaque, size: usize, nitems: usize, stream: *std.c.FILE) !usize {
    var items_written: usize = 0;

    while (items_written < nitems) {
        const items_remaining = nitems - items_written;
        const offset = items_written * size;
        const src: [*]const u8 = @ptrCast(ptr);

        const ret = std.c.fwrite(src + offset, size, items_remaining, stream);
        if (ret == 0) {
            const err = std.c._errno().*;
            if (err != @intFromEnum(std.posix.E.INTR)) {
                return error.WriteError;
            }
            // Retry on EINTR
            continue;
        }
        items_written += ret;
    }

    return items_written;
}

// Safe ftell - retries on EINTR
pub fn safeFtell(stream: *std.c.FILE) !i64 {
    while (true) {
        const offset = ftell(stream);
        if (offset != -1) {
            return offset;
        }

        const err = std.c._errno().*;
        if (err != @intFromEnum(std.posix.E.INTR)) {
            return error.SeekError;
        }
        // Retry on EINTR
    }
}

// Safe fseek - retries on EINTR
pub fn safeFseek(stream: *std.c.FILE, offset: i64, whence: i32) !void {
    // Convert Factor whence (0, 1, 2) to C SEEK_* constants
    const c_whence: c_int = switch (whence) {
        0 => std.c.SEEK.SET,
        1 => std.c.SEEK.CUR,
        2 => std.c.SEEK.END,
        else => {
            return error.SeekError;
        },
    };

    while (true) {
        const result = fseek(stream, offset, c_whence);
        if (result == 0) {
            return;
        }

        const err = std.c._errno().*;
        if (err != @intFromEnum(std.posix.E.INTR)) {
            return error.SeekError;
        }
        // Retry on EINTR
    }
}

// Safe fflush - retries on EINTR
pub fn safeFflush(stream: *std.c.FILE) !void {
    while (true) {
        const result = fflush(stream);
        if (result == 0) {
            return;
        }

        const err = std.c._errno().*;
        if (err != @intFromEnum(std.posix.E.INTR)) {
            return error.FlushError;
        }
        // Retry on EINTR
    }
}

// Clear error and EOF indicators on a stream
pub fn safeClearerr(stream: *std.c.FILE) void {
    clearerr(stream);
}

// Get current errno value
pub fn getErrno() i32 {
    return std.c._errno().*;
}

// Set errno value
pub fn setErrno(err: i32) void {
    std.c._errno().* = err;
}

// Initialize I/O subsystem
// Called once at VM startup
pub fn initIO(vm: *vm_mod.FactorVM) !void {
    // Initialize signal pipe for async signal delivery
    try initSignalPipe(vm);
}

// Shutdown I/O subsystem
pub fn deinitIO(vm: *vm_mod.FactorVM) void {
    deinitSignalPipe(vm);
}

// --- Tests ---

const TestFile = struct {
    tmp: std.testing.TmpDir,
    dir_path: [:0]u8,
    path: [:0]u8,

    fn init(name: []const u8) !TestFile {
        const testing = std.testing;
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        errdefer testing.allocator.free(dir_path);
        const path = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/{s}", .{ dir_path, name }, 0);
        return .{ .tmp = tmp, .dir_path = dir_path, .path = path };
    }

    fn deinit(self: *TestFile) void {
        std.testing.allocator.free(self.path);
        std.testing.allocator.free(self.dir_path);
        self.tmp.cleanup();
    }
};

test "safe file functions write, seek, tell and read back" {
    const testing = std.testing;
    var tf = try TestFile.init("io-test.bin");
    defer tf.deinit();

    const f = try safeFopen(tf.path.ptr, "wb");
    try testing.expectEqual(@as(usize, 5), try safeFwrite("hello", 1, 5, f));
    try safeFputc('!', f);
    try safeFflush(f);
    try testing.expectEqual(@as(i64, 6), try safeFtell(f));
    try safeFseek(f, 0, 0);
    try testing.expectEqual(@as(i64, 0), try safeFtell(f));
    try safeFseek(f, 0, 2);
    try testing.expectEqual(@as(i64, 6), try safeFtell(f));
    try safeFseek(f, -2, 1);
    try testing.expectEqual(@as(i64, 4), try safeFtell(f));
    try testing.expectError(error.SeekError, safeFseek(f, 0, 3));
    try safeFclose(f);

    const r = try safeFopen(tf.path.ptr, "rb");
    var buf: [16]u8 = undefined;
    // A short read at end of file returns the count rather than an error.
    try testing.expectEqual(@as(usize, 6), try safeFread(@ptrCast(&buf), 1, buf.len, r));
    try testing.expectEqualStrings("hello!", buf[0..6]);
    try testing.expectEqual(@as(usize, 0), try safeFread(@ptrCast(&buf), 1, 4, r));
    safeClearerr(r);
    // Multi-byte items: 3 items of 2 bytes.
    try safeFseek(r, 0, 0);
    try testing.expectEqual(@as(usize, 3), try safeFread(@ptrCast(&buf), 2, 3, r));
    try testing.expectEqualStrings("hello!", buf[0..6]);

    try safeFseek(r, 1, 0);
    for ("ello!") |expected| {
        try testing.expectEqual(@as(i32, expected), try safeFgetc(r));
    }
    try testing.expectEqual(@as(i32, EOF), try safeFgetc(r));
    try testing.expectEqual(@as(i32, EOF), try safeFgetc(r));
    safeClearerr(r);
    try safeFseek(r, 0, 0);
    try testing.expectEqual(@as(i32, 'h'), try safeFgetc(r));
    try safeFclose(r);
}

test "safeFopen reports a missing file as OpenError" {
    var tf = try TestFile.init("does-not-exist.bin");
    defer tf.deinit();
    try std.testing.expectError(error.OpenError, safeFopen(tf.path.ptr, "rb"));
}

test "errno accessors round trip" {
    setErrno(0);
    try std.testing.expectEqual(@as(i32, 0), getErrno());
    setErrno(42);
    try std.testing.expectEqual(@as(i32, 42), getErrno());
    setErrno(0);
}

test "signal pipe is created close-on-exec with a non-blocking write end" {
    const testing = std.testing;
    const vm = try vm_mod.FactorVM.init(testing.allocator);
    vm.vm_asm.ctx = try vm.newContext();
    vm.vm_asm.spare_ctx = try vm.newContext();
    defer vm.deinit();

    try testing.expectEqual(@as(i32, -1), vm.signal_pipe_input);
    try initIO(vm);
    try testing.expect(vm.signal_pipe_input >= 0);
    try testing.expect(vm.signal_pipe_output >= 0);
    try testing.expect(vm.signal_pipe_input != vm.signal_pipe_output);
    try testing.expectEqual(layouts.tagFixnum(vm.signal_pipe_input), vm.specialObject(.signal_pipe));

    try testing.expect(std.c.fcntl(vm.signal_pipe_input, F_GETFD) & FD_CLOEXEC != 0);
    try testing.expect(std.c.fcntl(vm.signal_pipe_output, F_GETFD) & FD_CLOEXEC != 0);
    try testing.expect(std.c.fcntl(vm.signal_pipe_output, F_GETFL) & O_NONBLOCK_C != 0);

    // Bytes written to the output end arrive on the input end.
    const msg = "sig";
    try testing.expectEqual(@as(isize, 3), std.c.write(vm.signal_pipe_output, msg, 3));
    var buf: [8]u8 = undefined;
    try testing.expectEqual(@as(isize, 3), std.c.read(vm.signal_pipe_input, &buf, buf.len));
    try testing.expectEqualStrings("sig", buf[0..3]);

    const in_fd = vm.signal_pipe_input;
    deinitIO(vm);
    try testing.expectEqual(@as(i32, -1), vm.signal_pipe_input);
    try testing.expectEqual(@as(i32, -1), vm.signal_pipe_output);
    // The descriptor is really closed.
    try testing.expect(std.c.fcntl(in_fd, F_GETFD) < 0);
    // A second deinit is a no-op.
    deinitIO(vm);
}
