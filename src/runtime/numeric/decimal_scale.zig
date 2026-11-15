// SPDX-License-Identifier: EPL-2.0
//! Checked BigDecimal scale arithmetic and scale-derived power bounds.

const std = @import("std");
const error_catalog = @import("../error/catalog.zig");

/// JVM checkScale saturates zero and names a positive out-of-range scale
/// "Underflow", a negative one "Overflow". Precision rounding instead uses
/// checkScaleNonZero, whose message follows the narrowed i32 sign (JDK 27).
pub const ScaleCheck = enum { nonzero, zero, precision };

pub fn checkScale(scale: i128, behavior: ScaleCheck) !i32 {
    if (std.math.cast(i32, scale)) |valid| return valid;
    const saturated: i32 = if (scale > 0) std.math.maxInt(i32) else std.math.minInt(i32);
    if (behavior == .zero) return saturated;
    const sign = if (behavior == .precision) @as(i32, @truncate(scale)) else saturated;
    return if (sign > 0)
        error_catalog.raise(.scale_underflow, .{}, .{})
    else
        error_catalog.raise(.scale_overflow, .{}, .{});
}

/// BigInteger's JVM limit is Integer.MAX_VALUE bits. 10^646456993 exceeds it.
/// Check before pow or a per-digit loop, not after attempting the allocation.
pub fn checkPowerOfTen(exponent: u64) !u32 {
    if (exponent > 646_456_992)
        return error_catalog.raise(.decimal_magnitude_overflow, .{}, .{});
    return @intCast(exponent);
}

const testing = std.testing;
const error_info = @import("../error/info.zig");

test "scale boundaries, zero saturation, and precision message direction" {
    const low = std.math.minInt(i32);
    const high = std.math.maxInt(i32);
    try testing.expectEqual(low, try checkScale(low, .nonzero));
    try testing.expectEqual(high, try checkScale(high, .nonzero));
    try testing.expectEqual(low, try checkScale(@as(i64, low) - 1, .zero));
    try testing.expectEqual(high, try checkScale(@as(i64, high) + 1, .zero));

    try testing.expectError(error.ArithmeticError, checkScale(@as(i64, low) - 1, .nonzero));
    try testing.expectEqualStrings("Overflow", error_info.getLastError().?.message);
    try testing.expectError(error.ArithmeticError, checkScale(@as(i64, high) + 1, .nonzero));
    try testing.expectEqualStrings("Underflow", error_info.getLastError().?.message);
    try testing.expectError(error.ArithmeticError, checkScale(@as(i64, low) - 1, .precision));
    try testing.expectEqualStrings("Underflow", error_info.getLastError().?.message);
    try testing.expectError(error.ArithmeticError, checkScale(@as(i64, high) + 1, .precision));
    try testing.expectEqualStrings("Overflow", error_info.getLastError().?.message);
}

test "power bounds are checked without constructing enormous integers" {
    try testing.expectEqual(@as(u32, 646_456_992), try checkPowerOfTen(646_456_992));
    try testing.expectError(error.ArithmeticError, checkPowerOfTen(646_456_993));
    try testing.expectEqualStrings("BigInteger would overflow supported range", error_info.getLastError().?.message);
    try testing.expectError(error.ArithmeticError, checkPowerOfTen(4_294_967_295));
    try testing.expectEqualStrings("BigInteger would overflow supported range", error_info.getLastError().?.message);
}
