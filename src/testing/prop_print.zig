//! Layer 7 (Property) — laws the printer obeys for every input. ADR-0186.
//!
//! The oracle is `std.fmt.parseFloat`, which shares no implementation with
//! `printFloat`, so agreement between them is evidence rather than a tautology.
//!
//! Boundaries the generator crosses on purpose: both zeros, both infinities,
//! NaN, the smallest denormal, `f64` max, and the decimal/exponent switch the
//! renderer makes around 1.0E7 and 1.0E-3.

const std = @import("std");
const prop = @import("prop.zig");
const build_options = @import("build_options");
const print = @import("../runtime/print.zig");

const Writer = std.Io.Writer;
const testing = std.testing;

/// Gate defaults, overridable for a sweep: `zig build test -Dprop-seed=0x… -Dprop-iters=…`.
fn config() prop.Config {
    return .{ .seed = build_options.prop_seed, .iters = build_options.prop_iters };
}

/// Values a uniform bit pattern would essentially never produce, drawn often
/// enough that every printer branch is reached.
const specials = [_]f64{
    0.0,                    -0.0,                       1.0,               -1.0,
    0.5,                    0.1,                        1.0e7,             9.999999e6,
    1.0e-3,                 9.99e-4,                    1.0e20,            1.0e-20,
    std.math.inf(f64),      -std.math.inf(f64),         std.math.nan(f64), std.math.floatMin(f64),
    std.math.floatMax(f64), std.math.floatTrueMin(f64),
};

/// A slice of f64 spanning the whole space: one third named boundaries, the
/// rest uniform 64-bit patterns (which include denormals and NaN payloads).
const FloatSlice = struct {
    max_len: usize = 24,

    pub fn generate(self: FloatSlice, rand: std.Random, alloc: std.mem.Allocator, size: usize) ![]f64 {
        const len = rand.uintLessThan(usize, @min(size, self.max_len) + 1);
        const out = try alloc.alloc(f64, len);
        for (out) |*slot| {
            slot.* = if (rand.uintLessThan(u8, 3) == 0)
                specials[rand.uintLessThan(usize, specials.len)]
            else
                @bitCast(rand.int(u64));
        }
        return out;
    }

    /// Drop a chunk, then halve one element toward zero.
    pub fn shrink(self: FloatSlice, alloc: std.mem.Allocator, v: []f64, out: *std.ArrayList([]f64)) !void {
        _ = self;
        if (v.len > 0) {
            try out.append(alloc, try alloc.dupe(f64, v[0 .. v.len / 2]));
            try out.append(alloc, try alloc.dupe(f64, v[v.len / 2 ..]));
        }
        for (v, 0..) |x, i| {
            if (x == 0 or !std.math.isFinite(x)) continue;
            const smaller = try alloc.dupe(f64, v);
            smaller[i] = x / 2.0;
            try out.append(alloc, smaller);
            break;
        }
    }

    pub fn free(self: FloatSlice, alloc: std.mem.Allocator, v: []f64) void {
        _ = self;
        alloc.free(v);
    }

    pub fn describe(self: FloatSlice, alloc: std.mem.Allocator, v: []f64) ![]u8 {
        _ = self;
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(alloc);
        try buf.append(alloc, '[');
        for (v, 0..) |x, i| {
            if (i > 0) try buf.appendSlice(alloc, ", ");
            try buf.print(alloc, "{d} (0x{x})", .{ x, @as(u64, @bitCast(x)) });
        }
        try buf.append(alloc, ']');
        return buf.toOwnedSlice(alloc);
    }
};

fn renderFloat(buf: []u8, f: f64) ![]const u8 {
    var w: Writer = .fixed(buf);
    try print.printFloat(&w, f);
    return w.buffered();
}

/// Every finite float prints to something that parses back to the SAME bits,
/// and every non-finite one prints to its reader literal.
fn roundTrips(_: void, xs: []f64) anyerror!void {
    var buf: [512]u8 = undefined;
    for (xs) |f| {
        const s = try renderFloat(&buf, f);
        if (std.math.isNan(f)) {
            try testing.expectEqualStrings("##NaN", s);
        } else if (std.math.isPositiveInf(f)) {
            try testing.expectEqualStrings("##Inf", s);
        } else if (std.math.isNegativeInf(f)) {
            try testing.expectEqualStrings("##-Inf", s);
        } else {
            const back = std.fmt.parseFloat(f64, s) catch return error.PrintedFloatDoesNotParse;
            // Bit equality, not `==`: it separates 0.0 from -0.0, which `==` does not.
            if (@as(u64, @bitCast(back)) != @as(u64, @bitCast(f))) return error.FloatRoundTripLostBits;
        }
    }
}

/// A finite float always prints something a Clojure reader can take back as a
/// float: a digit is present, and the only non-digit characters are the ones
/// float syntax allows.
fn readableShape(_: void, xs: []f64) anyerror!void {
    var buf: [512]u8 = undefined;
    for (xs) |f| {
        if (!std.math.isFinite(f)) continue;
        const s = try renderFloat(&buf, f);
        if (s.len == 0) return error.EmptyRendering;
        var saw_digit = false;
        for (s) |c| switch (c) {
            '0'...'9' => saw_digit = true,
            '.', '-', '+', 'E' => {},
            else => return error.UnexpectedCharacterInFloat,
        };
        if (!saw_digit) return error.NoDigitsInFloat;
        // A float must not render as an integer literal, or reading it back
        // yields a Long.
        if (std.mem.indexOfAny(u8, s, ".E") == null) return error.FloatRendersAsInteger;
    }
}

test "property: printFloat output re-parses to the same f64" {
    try prop.forAll([]f64, testing.allocator, config(), FloatSlice{}, {}, roundTrips);
}

test "property: a finite float renders as float syntax, never integer syntax" {
    try prop.forAll([]f64, testing.allocator, config(), FloatSlice{}, {}, readableShape);
}
