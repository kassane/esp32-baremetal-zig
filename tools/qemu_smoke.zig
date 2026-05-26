// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

//! Host-native QEMU boot smoke test, invoked by `zig build smoke`.
//!
//! Usage: qemu_smoke <qemu-bin> <machine> <kernel-elf> <seconds> [serial-out-file]
//!
//! Boots the firmware in qemu-system-xtensa for <seconds>, then asserts:
//!   * QEMU did NOT exit on its own (the blink loop runs forever, so the
//!     firmware still executing when the timer fires is the success case), and
//!   * no CPU fault was reported (-d guest_errors,unimp).
//! Exits 0 on pass, non-zero on failure (printing the captured QEMU output).
//!
//! Portable (Linux/macOS/Windows): spawns through std.process and drains both
//! pipes with std.Io.File.MultiReader. A watchdog thread terminates QEMU after
//! the budget — a read timeout isn't honored on every backend, so the watchdog
//! (not the read) is what bounds the run; the firmware never exits on its own,
//! so the watchdog firing (rather than an early EndOfStream) is the pass case.

const std = @import("std");
const builtin = @import("builtin");

const fault_markers = [_][]const u8{
    "exception", "unhandled", "unimplemented", "illegal", "guest_error", "fault",
};

// Read headroom requested per `MultiReader.fill`; the captured output is small.
const fill_reserve = 64;
// argv layout: self, qemu, machine, kernel, seconds, [serial-out-file].
const argc_min = 5; // without the optional serial-out file
const argc_max = 6; // with it

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

fn fail(machine: []const u8, reason: []const u8, out: []const u8, err: []const u8) noreturn {
    std.debug.print("FAIL: {s} {s}:\n{s}{s}\n", .{ machine, reason, out, err });
    std.process.exit(1);
}

/// Forcibly terminate the child by pid/handle without going through
/// `child.kill` (which would also close the pipes the reader is draining).
fn terminate(child: *std.process.Child) void {
    if (builtin.os.tag == .windows) {
        _ = std.os.windows.ntdll.NtTerminateProcess(child.id.?, .SUCCESS);
    } else {
        std.posix.kill(child.id.?, std.posix.SIG.TERM) catch {};
    }
}

const Watchdog = struct {
    child: *std.process.Child,
    io: std.Io,
    seconds: u32,
    fired: std.atomic.Value(bool),

    fn run(self: *Watchdog) void {
        const budget: std.Io.Clock.Duration = .{
            .raw = std.Io.Duration.fromSeconds(self.seconds),
            .clock = .awake,
        };
        budget.sleep(self.io) catch {};
        self.fired.store(true, .seq_cst); // set before terminate, so an EOF
        terminate(self.child); // caused by us reads back as fired == true
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len < argc_min or args.len > argc_max) {
        std.debug.print("usage: {s} <qemu-bin> <machine> <kernel-elf> <seconds> [serial-out-file]\n", .{args[0]});
        std.process.exit(2);
    }
    const qemu = args[1];
    const machine = args[2];
    const kernel = args[3];
    const seconds = try std.fmt.parseInt(u32, args[4], 10);
    // When a serial-out path is given, route the UART there and print it after
    // the run — turns `smoke` into a `demo` that shows the example's output.
    const serial_out: ?[]const u8 = if (args.len == argc_max) args[argc_min] else null;

    std.debug.print("smoke: booting {s} on machine '{s}' for {d}s ...\n", .{ kernel, machine, seconds });

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(gpa, &.{ qemu, "-nographic", "-machine", machine, "-kernel", kernel, "-d", "guest_errors,unimp" });
    if (serial_out) |path| {
        try argv.append(gpa, "-serial");
        try argv.append(gpa, try std.fmt.allocPrint(gpa, "file:{s}", .{path}));
    }

    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io); // terminate (no-op if dead) + reap + close pipes

    var wd: Watchdog = .{ .child = &child, .io = io, .seconds = seconds, .fired = .init(false) };
    const watchdog = try std.Thread.spawn(.{}, Watchdog.run, .{&wd});

    // Drain both pipes until QEMU's fds close (it exited, or the watchdog
    // terminated it). No read timeout — the watchdog bounds the run.
    var mrb: std.Io.File.MultiReader.Buffer(2) = undefined;
    var mr: std.Io.File.MultiReader = undefined;
    mr.init(gpa, io, mrb.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer mr.deinit();
    while (mr.fill(fill_reserve, .none)) |_| {} else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }
    // Sample the flag at EOF (before join): true ⇒ the watchdog ended the run.
    const timed_out = wd.fired.load(.seq_cst);
    watchdog.join();

    const out = mr.reader(0).buffered();
    const err_out = mr.reader(1).buffered();

    if (firstFault(err_out) orelse firstFault(out)) |marker| {
        fail(machine, try std.fmt.allocPrint(gpa, "reported a CPU fault (matched '{s}')", .{marker}), out, err_out);
    }
    if (!timed_out) {
        fail(machine, "exited before the timeout; the firmware should loop forever", out, err_out);
    }

    if (serial_out) |path| {
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch "";
        std.debug.print("─── {s} UART output ───\n{s}\n───────────────────────\n", .{ machine, text });
    }

    std.debug.print("PASS: {s} booted and ran {d}s with no CPU faults.\n", .{ machine, seconds });
}
