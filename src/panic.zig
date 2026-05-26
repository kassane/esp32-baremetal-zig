// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

//! Custom panic namespace replacing std's `debug.FullPanic`, whose helpers
//! format via `std.fmt`/`Io.Writer` — i.e. the very panic path that can't link
//! here. A root `pub const panic = <namespace>` overrides it (std.builtin.panic),
//! routing every safety check to the root-supplied `call`, which forwards to
//! `mmio.panic` (UART message + best-effort backtrace, no std.fmt).
//!
//! Note: this prebuilt xtensa backend emits no non-inline (far) calls, so the
//! firmware elides all safety checks and never lets the compiler *dispatch* a
//! panic; faults are reported by calling `mmio.panic` directly (works in Release,
//! verified in QEMU). The namespace keeps the std interface correct meanwhile.

/// Build the namespace from a root-side `call` forwarding to `mmio.panic`:
/// `pub const panic = @import("panic").Handler(onPanic);`
pub fn Handler(comptime call_fn: fn ([]const u8, ?usize) noreturn) type {
    return struct {
        /// Core handler (`@panic`, `unreachable`, …): message + backtrace + halt.
        pub const call = call_fn;

        // std renders these with the offending values; we keep the static text
        // and let the backtrace pin the location (formatting can't link here).
        pub fn sentinelMismatch(_: anytype, _: anytype) noreturn {
            call("sentinel mismatch", @returnAddress());
        }
        pub fn unwrapError(_: anyerror) noreturn {
            call("attempt to unwrap error", @returnAddress());
        }
        pub fn outOfBounds(_: usize, _: usize) noreturn {
            call("index out of bounds", @returnAddress());
        }
        pub fn startGreaterThanEnd(_: usize, _: usize) noreturn {
            call("start index is larger than end index", @returnAddress());
        }
        pub fn inactiveUnionField(_: anytype, _: anytype) noreturn {
            call("access of inactive union field", @returnAddress());
        }
        pub fn sliceCastLenRemainder(_: usize) noreturn {
            call("slice length does not divide exactly", @returnAddress());
        }

        // Fixed-message safety checks.
        pub fn reachedUnreachable() noreturn {
            call("reached unreachable code", @returnAddress());
        }
        pub fn unwrapNull() noreturn {
            call("attempt to use null value", @returnAddress());
        }
        pub fn castToNull() noreturn {
            call("cast causes pointer to be null", @returnAddress());
        }
        pub fn incorrectAlignment() noreturn {
            call("incorrect alignment", @returnAddress());
        }
        pub fn invalidErrorCode() noreturn {
            call("invalid error code", @returnAddress());
        }
        pub fn integerOutOfBounds() noreturn {
            call("integer does not fit in destination type", @returnAddress());
        }
        pub fn integerOverflow() noreturn {
            call("integer overflow", @returnAddress());
        }
        pub fn shlOverflow() noreturn {
            call("left shift overflowed bits", @returnAddress());
        }
        pub fn shrOverflow() noreturn {
            call("right shift overflowed bits", @returnAddress());
        }
        pub fn divideByZero() noreturn {
            call("division by zero", @returnAddress());
        }
        pub fn exactDivisionRemainder() noreturn {
            call("exact division produced remainder", @returnAddress());
        }
        pub fn integerPartOutOfBounds() noreturn {
            call("integer part of float out of bounds", @returnAddress());
        }
        pub fn corruptSwitch() noreturn {
            call("switch on corrupt value", @returnAddress());
        }
        pub fn shiftRhsTooBig() noreturn {
            call("shift amount is greater than the type size", @returnAddress());
        }
        pub fn invalidEnumValue() noreturn {
            call("invalid enum value", @returnAddress());
        }
        pub fn forLenMismatch() noreturn {
            call("for loop over non-equal lengths", @returnAddress());
        }
        pub fn copyLenMismatch() noreturn {
            call("source and destination have non-equal lengths", @returnAddress());
        }
        pub fn memcpyAlias() noreturn {
            call("@memcpy arguments alias", @returnAddress());
        }
        pub fn noreturnReturned() noreturn {
            call("'noreturn' function returned", @returnAddress());
        }
    };
}
