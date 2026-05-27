// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

//! A bare-metal bump arena — fixed-capacity and typed.
//!
//! `std.mem.Allocator` now works in **Release** builds: dropping `-fstrip` made
//! its vtable dispatch link (see docs/internals.md), and `FixedBufferAllocator
//! .alloc` runs correctly under `ReleaseSmall`/`ReleaseFast` (QEMU-verified). In
//! **Debug** it hangs — its non-inline alloc chain nests past the windowed-ABI
//! register-window overflow that this Zig fork / QEMU mishandle for deep calls
//! (see docs/internals.md); Release inlines the chain shallow, so it survives. So
//! the std allocator isn't safe across all modes. This typed arena, by contrast,
//! is `inline` and panic-free (a static `[capacity]T` buffer, naturally
//! `@alignOf(T)`-aligned, sliced through a many-item pointer — no bounds/alignment
//! check) and works in every build mode, so it stays the default. `reset()` frees
//! the whole region at once.
//!
//! (There is no OS page allocator freestanding; for reference `std.heap` reports a
//! 4 KiB page size for the esp32* targets.)

const std = @import("std");

/// A bump arena holding up to `capacity` values of `T`. Usage:
/// `const Pool = heap.Arena(u32, 256); const xs = Pool.alloc(8) orelse …;`
pub fn Arena(comptime T: type, comptime capacity: usize) type {
    return struct {
        var buffer: [capacity]T = undefined;
        var used_count: usize = 0;

        /// Bump-allocate `n` contiguous `T`, or `null` if the arena is full.
        pub inline fn alloc(n: usize) ?[]T {
            if (used_count +% n > capacity) return null;
            const start = used_count;
            used_count +%= n;
            const base: [*]T = &buffer;
            return (base + start)[0..n];
        }
        /// Allocate one uninitialised `T`, or `null` if the arena is full.
        pub inline fn create() ?*T {
            const slot = alloc(1) orelse return null;
            return &slot.ptr[0];
        }
        /// Free every allocation at once (reset the bump offset to the start).
        pub inline fn reset() void {
            used_count = 0;
        }
        /// Items allocated so far.
        pub inline fn used() usize {
            return used_count;
        }
        /// Total capacity, in items of `T`.
        pub const items = capacity;
    };
}
