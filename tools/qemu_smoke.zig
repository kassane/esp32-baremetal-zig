//! Host-native QEMU boot smoke test, invoked by `zig build smoke`.
//!
//! Usage: qemu_smoke <qemu-bin> <machine> <kernel-elf> <seconds>
//!
//! Boots the firmware in qemu-system-xtensa for <seconds>, then asserts:
//!   * QEMU did NOT exit on its own (the blink loop runs forever, so the
//!     firmware still executing when the timer fires is the success case), and
//!   * no CPU fault was reported (-d guest_errors,unimp).
//! Exits 0 on pass, non-zero on failure (printing the captured QEMU output).
//!
//! Built for the host and driven through the raw Linux syscall layer so it does
//! not depend on the (currently in-flux) std process/Io abstractions.

const std = @import("std");
const linux = std.os.linux;

const fault_markers = [_][]const u8{
    "exception", "unhandled", "unimplemented", "illegal", "guest_error", "fault",
};

inline fn signed(x: usize) isize {
    return @bitCast(x);
}

fn sleepMs(ms: u64) void {
    var req = linux.timespec{
        .sec = @intCast(ms / std.time.ms_per_s),
        .nsec = @intCast((ms % std.time.ms_per_s) * std.time.ns_per_ms),
    };
    _ = linux.nanosleep(&req, null);
}

fn indexOfIgnoreCase(hay: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or hay.len < needle.len) return null;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(hay[i + j]) != needle[j]) break;
        }
        if (j == needle.len) return i;
    }
    return null;
}

fn firstFault(hay: []const u8) ?[]const u8 {
    for (fault_markers) |m| {
        if (indexOfIgnoreCase(hay, m) != null) return m;
    }
    return null;
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 5 and args.len != 6) {
        std.debug.print("usage: {s} <qemu-bin> <machine> <kernel-elf> <seconds> [serial-out-file]\n", .{args[0]});
        linux.exit(2);
    }
    const qemu = args[1];
    const machine = args[2];
    const kernel = args[3];
    const seconds = try std.fmt.parseInt(u32, args[4], 10);
    // When a serial-out path is given, route the UART there and print it after
    // the run — turns `smoke` into a `demo` that shows the example's output.
    const serial_out: ?[]const u8 = if (args.len == 6) args[5] else null;

    std.debug.print("smoke: booting {s} on machine '{s}' for {d}s ...\n", .{ kernel, machine, seconds });

    // Build argv (host tool → normal allocation/indexing is fine here).
    const gpa = init.arena.allocator();
    var argv_list: std.ArrayList(?[*:0]const u8) = .empty;
    try argv_list.appendSlice(gpa, &.{
        qemu.ptr, "-nographic", "-machine", machine.ptr, "-kernel", kernel.ptr, "-d", "guest_errors,unimp",
    });
    if (serial_out) |path| {
        try argv_list.append(gpa, "-serial");
        try argv_list.append(gpa, (try std.fmt.allocPrintSentinel(gpa, "file:{s}", .{path}, 0)).ptr);
    }
    try argv_list.append(gpa, null);
    const argv: [*:null]const ?[*:0]const u8 = @ptrCast(argv_list.items.ptr);
    const envp = [_:null]?[*:0]const u8{};

    var fds: [2]i32 = undefined;
    if (signed(linux.pipe(&fds)) < 0) return error.PipeFailed;

    const fork_rc = linux.fork();
    if (signed(fork_rc) < 0) return error.ForkFailed;
    const pid: i32 = @intCast(signed(fork_rc));

    if (pid == 0) {
        // Child: send stdout+stderr to the pipe, then exec QEMU.
        _ = linux.close(fds[0]);
        _ = linux.dup2(fds[1], 1);
        _ = linux.dup2(fds[1], 2);
        _ = linux.close(fds[1]);
        _ = linux.execve(qemu.ptr, argv, &envp);
        linux.exit(127); // exec failed
    }

    // Parent.
    _ = linux.close(fds[1]);

    var status: u32 = 0;
    var exited_early = false;
    var elapsed_ms: u64 = 0;
    const budget_ms = @as(u64, seconds) * std.time.ms_per_s;
    while (elapsed_ms < budget_ms) {
        if (signed(linux.wait4(pid, &status, linux.W.NOHANG, null)) > 0) {
            exited_early = true;
            break;
        }
        sleepMs(100);
        elapsed_ms += 100;
    }
    if (!exited_early) _ = linux.kill(pid, .TERM);

    // Drain combined stdout/stderr (smoke output is tiny).
    var buf: [1 << 16]u8 = undefined;
    var len: usize = 0;
    while (len < buf.len) {
        const n = linux.read(fds[0], buf[len..].ptr, buf.len - len);
        if (signed(n) <= 0) break;
        len += n;
    }
    _ = linux.close(fds[0]);
    if (!exited_early) _ = linux.wait4(pid, &status, 0, null);
    const output = buf[0..len];

    if (firstFault(output)) |marker| {
        std.debug.print("FAIL: {s} reported a CPU fault (matched '{s}'):\n{s}\n", .{ machine, marker, output });
        linux.exit(1);
    }
    if (exited_early) {
        std.debug.print("FAIL: {s} QEMU exited before the timeout; the firmware should loop forever:\n{s}\n", .{ machine, output });
        linux.exit(1);
    }

    if (serial_out) |path| {
        const text = std.Io.Dir.cwd().readFileAlloc(init.io, path, gpa, .unlimited) catch "";
        std.debug.print("─── {s} UART output ───\n{s}\n───────────────────────\n", .{ machine, text });
    }

    std.debug.print("PASS: {s} booted and ran {d}s with no CPU faults.\n", .{ machine, seconds });
}
