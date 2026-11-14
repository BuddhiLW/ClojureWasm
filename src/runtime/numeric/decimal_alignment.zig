// SPDX-License-Identifier: EPL-2.0
//! Decimal scale alignment for exact and precision-bounded addition/subtraction.
//!
//! A finite precision needs guard digits and the sign of a distant nonzero
//! tail, not a power of ten spanning the entire gap between the operands.

const std = @import("std");
const Managed = std.math.big.int.Managed;
const digitCount = @import("decimal_text.zig").digitCount;

pub const Operation = enum { add, sub };
pub const Operand = struct { unscaled: *const Managed, scale: i32 };
pub const Result = struct { unscaled: Managed, scale: i32 };

/// Combine at the preferred (larger) scale. With finite precision, replace a
/// disjoint low-order tail by a signed sticky digit before aligning. The caller
/// rounds the returned unscaled value once, using its requested rounding mode.
pub fn combine(alloc: std.mem.Allocator, a: Operand, b: Operand, op: Operation, precision: u32) !Result {
    var left = a;
    var right = b;
    var sticky = try Managed.init(alloc);
    defer sticky.deinit();
    if (precision != 0) {
        const coarse = if (a.scale < b.scale) a else b;
        const fine = if (a.scale < b.scale) b else a;
        if (!coarse.unscaled.eqlZero()) {
            const coarse_digits: i64 = @intCast(try digitCount(alloc, coarse.unscaled));
            const fine_digits: i64 = @intCast(try digitCount(alloc, fine.unscaled));
            // Stay below BOTH the coarse operand's least significant digit and
            // the rounding ULP. Two guard places retain borrow/carry and which
            // side of a half tie the exact sum lies on, for every rounding mode.
            const rounding_scale = @as(i64, coarse.scale) + precision - coarse_digits;
            const sticky_scale = @max(@as(i64, coarse.scale), rounding_scale) + 2;
            const fine_top_scale = @as(i64, fine.scale) - fine_digits + 1;
            if (fine_top_scale > sticky_scale) {
                try sticky.set(if (fine.unscaled.eqlZero()) @as(i8, 0) else if (fine.unscaled.isPositive()) @as(i8, 1) else @as(i8, -1));
                const tail: Operand = .{ .unscaled = &sticky, .scale = @intCast(sticky_scale) };
                if (a.scale < b.scale) right = tail else left = tail;
            }
        }
    }
    const scale = @max(left.scale, right.scale);
    var aligned_a = try cloneAndScale(alloc, left.unscaled, @intCast(@as(i64, scale) - left.scale));
    defer aligned_a.deinit();
    var aligned_b = try cloneAndScale(alloc, right.unscaled, @intCast(@as(i64, scale) - right.scale));
    defer aligned_b.deinit();
    var unscaled = try Managed.init(alloc);
    errdefer unscaled.deinit();
    switch (op) {
        .add => try unscaled.add(&aligned_a, &aligned_b),
        .sub => try unscaled.sub(&aligned_a, &aligned_b),
    }
    return .{ .unscaled = unscaled, .scale = scale };
}

/// Clone and scale by 10^extra_scale. Zero needs no power; nonzero alignment
/// uses std's exponentiation rather than a linear chain of growing products.
pub fn cloneAndScale(alloc: std.mem.Allocator, src: *const Managed, extra_scale: u32) !Managed {
    var out = try src.cloneWithDifferentAllocator(alloc);
    errdefer out.deinit();
    if (extra_scale == 0 or src.eqlZero()) return out;
    var ten = try Managed.initSet(alloc, 10);
    defer ten.deinit();
    var multiplier = try Managed.init(alloc);
    defer multiplier.deinit();
    try multiplier.pow(&ten, extra_scale);
    var product = try Managed.init(alloc);
    defer product.deinit();
    try product.mul(&out, &multiplier);
    out.swap(&product);
    return out;
}
