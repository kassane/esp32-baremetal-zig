// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

//! Comptime register-field helpers. Drivers describe a peripheral register by
//! naming its bit fields (offset + width, straight from the SVD/TRM) instead of
//! hand-shifting magic numbers like `1 << 4` or `value << 13`. Everything folds
//! at comptime, so the generated code is identical to the literal version — but
//! the source documents *which* field each bit is. Modelled on the bit-twiddling
//! in `std.math` / `std.mem` (shifts typed as `std.math.Log2Int(u32)`).

const std = @import("std");

/// Shift amount for a `u32` (`u5`), the type Zig requires for `<<`/`>>`.
const Shift = std.math.Log2Int(u32);

/// A single-bit flag at position `n` — e.g. `const ms_mode = reg.bit(4);`.
pub inline fn bit(comptime n: Shift) u32 {
    return @as(u32, 1) << n;
}

/// A contiguous bit field `[lsb +: width]` of a 32-bit register. Use `.set(v)` to
/// place a value (masked to the field) and `.get(r)` to extract it; `.mask` is
/// the field's bit mask. `width` up to 32 is handled without shift overflow.
pub fn Field(comptime lsb: Shift, comptime width: u6) type {
    if (width == 0 or @as(u32, lsb) + width > 32) @compileError("field out of range");
    return struct {
        pub const shift = lsb;
        pub const mask: u32 = if (width == 32) ~@as(u32, 0) else ((@as(u32, 1) << @intCast(width)) - 1) << lsb;

        /// `value` placed at the field's position, masked so it can't bleed into
        /// neighbouring fields. OR these together to compose a register word.
        pub inline fn set(value: u32) u32 {
            return (value << lsb) & mask;
        }
        /// Extract the field's value from a full register word `r`.
        pub inline fn get(r: u32) u32 {
            return (r & mask) >> lsb;
        }
    };
}
