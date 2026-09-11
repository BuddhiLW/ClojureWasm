// SPDX-License-Identifier: EPL-2.0
//! Murmur3 hash for ClojureWasm — Clojure-compatible hash values.
//!
//! Mirrors `clojure.lang.Murmur3` in Clojure JVM. All multiplications
//! and additions wrap (`*%` / `+%`) to match Java's `int` overflow
//! semantics; that's load-bearing for value hashes to round-trip
//! correctly across runtimes (e.g. when comparing `hash` results in a
//! shared test).
//!
//! `hashString` hashes UTF-8 bytes directly, **not** the UTF-16 code
//! units that Clojure JVM hashes. This matches v1's choice and trades
//! exact-bit compatibility for working in a Wasm/edge environment
//! where UTF-8 is the natural encoding.

const std = @import("std");

const C1: u32 = 0xcc9e2d51;
const C2: u32 = 0x1b873593;
const SEED: u32 = 0;

fn mixK1(k: u32) u32 {
    var k1 = k;
    k1 *%= C1;
    k1 = std.math.rotl(u32, k1, 15);
    k1 *%= C2;
    return k1;
}

fn mixH1(h: u32, k1: u32) u32 {
    var h1 = h;
    h1 ^= k1;
    h1 = std.math.rotl(u32, h1, 13);
    h1 = h1 *% 5 +% 0xe6546b64;
    return h1;
}

fn fmix(h: u32, length: u32) u32 {
    var h1 = h;
    h1 ^= length;
    h1 ^= h1 >> 16;
    h1 *%= 0x85ebca6b;
    h1 ^= h1 >> 13;
    h1 *%= 0xc2b2ae35;
    h1 ^= h1 >> 16;
    return h1;
}

/// Hash a 32-bit integer. `0` hashes to `0` (Clojure compat).
pub fn hashInt(input: i32) u32 {
    if (input == 0) return 0;
    const k1 = mixK1(@bitCast(input));
    const h1 = mixH1(SEED, k1);
    return fmix(h1, 4);
}

/// Hash a 64-bit integer. `0` hashes to `0`.
pub fn hashLong(input: i64) u32 {
    if (input == 0) return 0;
    const bits: u64 = @bitCast(input);
    const low: u32 = @truncate(bits);
    const high: u32 = @truncate(bits >> 32);
    var h1 = mixH1(SEED, mixK1(low));
    h1 = mixH1(h1, mixK1(high));
    return fmix(h1, 8);
}

/// Hash a UTF-8 byte string.
pub fn hashString(input: []const u8) u32 {
    var h1: u32 = SEED;
    const nblocks = input.len / 4;

    for (0..nblocks) |i| {
        const offset = i * 4;
        const k: u32 = @as(u32, input[offset]) |
            (@as(u32, input[offset + 1]) << 8) |
            (@as(u32, input[offset + 2]) << 16) |
            (@as(u32, input[offset + 3]) << 24);
        h1 = mixH1(h1, mixK1(k));
    }

    const tail_offset = nblocks * 4;
    var k1: u32 = 0;
    const tail_len = input.len - tail_offset;
    if (tail_len >= 3) k1 ^= @as(u32, input[tail_offset + 2]) << 16;
    if (tail_len >= 2) k1 ^= @as(u32, input[tail_offset + 1]) << 8;
    if (tail_len >= 1) {
        k1 ^= @as(u32, input[tail_offset]);
        h1 ^= mixK1(k1);
    }

    return fmix(h1, @truncate(input.len));
}

/// Decode ONE codepoint at `i.*`, LOSSILY: a byte sequence that is not valid
/// UTF-8 yields U+FFFD and advances a single byte.
///
/// A cljw String is raw BYTES (AD-009), so it can hold input that is not
/// UTF-8 at all: a file read with `slurp`, a buffer handed over by a Wasm
/// guest. `Utf8View.initUnchecked` promises the caller already validated,
/// and its iterator then reads past the end of a truncated sequence and
/// trips `unreachable`. That is not a catchable Clojure error, it ABORTS the
/// process: `(hash (slurp "some.wasm"))` used to core-dump cljw and take the
/// REPL with it.
///
/// Hashing has to be TOTAL, because a value that cannot be hashed cannot go
/// in a map, and a String is not allowed to be un-mappable for a reason the
/// caller cannot see. Replacement keeps the hash defined over every byte
/// string while leaving VALID UTF-8 byte-identical to what the checked
/// iterator produced, so no JVM parity claim moves. Two distinct invalid
/// strings may now collide, which a hash is permitted to do; `=` still
/// compares the bytes.
fn nextCodepointLossy(utf8: []const u8, i: *usize) ?u21 {
    if (i.* >= utf8.len) return null;
    const first = utf8[i.*];
    const len = std.unicode.utf8ByteSequenceLength(first) catch {
        i.* += 1;
        return 0xFFFD;
    };
    if (i.* + len > utf8.len) {
        i.* += 1;
        return 0xFFFD;
    }
    // The fixed-width utf8DecodeN take an ARRAY, which is what makes them the
    // non-deprecated spelling: the length is comptime per branch, so a caller
    // cannot hand them a slice whose length disagrees with its lead byte.
    // `utf8Decode`'s slice API is deprecated for exactly that hazard.
    const cp: u21 = switch (len) {
        1 => first,
        2 => std.unicode.utf8Decode2(utf8[i.*..][0..2].*) catch {
            i.* += 1;
            return 0xFFFD;
        },
        3 => std.unicode.utf8Decode3(utf8[i.*..][0..3].*) catch {
            i.* += 1;
            return 0xFFFD;
        },
        4 => std.unicode.utf8Decode4(utf8[i.*..][0..4].*) catch {
            i.* += 1;
            return 0xFFFD;
        },
        // utf8ByteSequenceLength answers 1..4 or errors, so this is dead. It
        // replaces what would idiomatically be `unreachable`: this function
        // exists BECAUSE an unreachable on malformed input aborted the
        // process, and re-introducing one here would be the same bet.
        else => {
            i.* += 1;
            return 0xFFFD;
        },
    };
    i.* += len;
    return cp;
}

/// JVM `clojure.lang.Murmur3.hashUnencodedChars` bit-parity: Murmur3 over
/// the string's UTF-16 CODE UNITS (surrogate pairs for astral codepoints),
/// two units per 32-bit block, `fmix` over `2 * unit-count` bytes. Distinct
/// from `hashString` (cljw-native UTF-8 bytes, AD-009) — this serves the
/// `Murmur3/hashUnencodedChars` static (data.xml), where JVM value-parity is
/// achievable because the input is pure code units, not value identity (D-376).
pub fn hashUnencodedChars(utf8: []const u8) u32 {
    var h1: u32 = SEED;
    var unit_count: u32 = 0;
    var pending: ?u32 = null;
    var i: usize = 0;
    while (nextCodepointLossy(utf8, &i)) |cp| {
        var units: [2]u32 = .{ @as(u32, cp), 0 };
        var n: usize = 1;
        if (cp >= 0x10000) {
            const v: u32 = @as(u32, cp) - 0x10000;
            units[0] = 0xD800 + (v >> 10);
            units[1] = 0xDC00 + (v & 0x3FF);
            n = 2;
        }
        for (units[0..n]) |u| {
            unit_count += 1;
            if (pending) |lo| {
                h1 = mixH1(h1, mixK1(lo | (u << 16)));
                pending = null;
            } else {
                pending = u;
            }
        }
    }
    if (pending) |lo| h1 ^= mixK1(lo);
    return fmix(h1, 2 *% unit_count);
}

/// Java `String.hashCode`: the 31-fold over UTF-16 code units (surrogate
/// pairs for astral codepoints). Feeds `hashInt` for clj's String hasheq
/// and `hashCombine` for the Symbol/Keyword hasheq ns part.
pub fn javaStringHashCode(utf8: []const u8) i32 {
    var h: i32 = 0;
    var i: usize = 0;
    while (nextCodepointLossy(utf8, &i)) |cp| {
        if (cp >= 0x10000) {
            const v: u32 = @as(u32, cp) - 0x10000;
            h = h *% 31 +% @as(i32, @intCast(0xD800 + (v >> 10)));
            h = h *% 31 +% @as(i32, @intCast(0xDC00 + (v & 0x3FF)));
        } else {
            h = h *% 31 +% @as(i32, @intCast(cp));
        }
    }
    return h;
}

/// `java.math.BigInteger.hashCode` for an i64-fitting value: the 31-fold
/// over the magnitude's 32-bit words, times the signum. Backs clj's Ratio
/// (num.hashCode ^ den.hashCode) and normalized-BigDecimal
/// (31*unscaled.hashCode + scale) hasheq values.
pub fn javaBigIntegerHashCodeI64(v: i64) i32 {
    if (v == 0) return 0;
    const neg = v < 0;
    const abs: u64 = if (neg) @as(u64, @intCast(-(v + 1))) + 1 else @intCast(v);
    const hi: u32 = @truncate(abs >> 32);
    const lo: u32 = @truncate(abs);
    var h: i32 = 0;
    if (hi != 0) h = 31 *% h +% @as(i32, @bitCast(hi));
    h = 31 *% h +% @as(i32, @bitCast(lo));
    return if (neg) -%h else h;
}

/// `clojure.lang.Util.hashCombine` (the boost-style combiner Symbol.hasheq
/// folds its ns hash with).
pub fn hashCombine(seed_val: u32, hash_val: u32) u32 {
    const seed: i32 = @bitCast(seed_val);
    const h: i32 = @bitCast(hash_val);
    const golden: i32 = @bitCast(@as(u32, 0x9e3779b9));
    return @bitCast(seed ^ (h +% golden +% (seed << 6) +% (seed >> 2)));
}

/// Mix a precomputed collection hash with its element count.
pub fn mixCollHash(hash_val: u32, count: u32) u32 {
    var h1 = SEED;
    const k1 = mixK1(hash_val);
    h1 = mixH1(h1, k1);
    return fmix(h1, count);
}

/// Order-dependent combination (vectors, lists). `h := 31*h + element`.
pub fn hashOrdered(hashes: []const u32) u32 {
    var h: u32 = 1;
    for (hashes) |elem_hash| {
        h = h *% 31 +% elem_hash;
    }
    return mixCollHash(h, @truncate(hashes.len));
}

/// Order-independent combination (sets, map keysets).
pub fn hashUnordered(hashes: []const u32) u32 {
    var h: u32 = 0;
    for (hashes) |elem_hash| {
        h +%= elem_hash;
    }
    return mixCollHash(h, @truncate(hashes.len));
}

// --- tests ---

const testing = std.testing;

test "hashInt(0) is zero (Clojure compat)" {
    try testing.expectEqual(@as(u32, 0), hashInt(0));
}

test "hashInt is deterministic and discriminates sign" {
    const h_pos = hashInt(42);
    try testing.expect(h_pos != 0);
    try testing.expectEqual(h_pos, hashInt(42));

    const h_neg = hashInt(-1);
    try testing.expect(h_neg != 0);
    try testing.expect(h_neg != hashInt(1));
}

test "hashLong(0) is zero; non-zero values hash deterministically" {
    try testing.expectEqual(@as(u32, 0), hashLong(0));
    const h = hashLong(42);
    try testing.expect(h != 0);
    try testing.expectEqual(h, hashLong(42));
    try testing.expect(hashLong(1 << 48) != 0);
}

test "hashString deterministic; empty handled; lengths discriminate" {
    try testing.expectEqual(hashString(""), hashString(""));
    const h = hashString("hello");
    try testing.expect(h != 0);
    try testing.expectEqual(h, hashString("hello"));
    try testing.expect(h != hashString("world"));

    const h1 = hashString("a");
    const h2 = hashString("ab");
    const h3 = hashString("abc");
    const h4 = hashString("abcd");
    const h5 = hashString("abcde");
    try testing.expect(h1 != h2);
    try testing.expect(h2 != h3);
    try testing.expect(h3 != h4);
    try testing.expect(h4 != h5);
}

test "mixCollHash differs on different counts" {
    const h = mixCollHash(12345, 3);
    try testing.expectEqual(h, mixCollHash(12345, 3));
    try testing.expect(h != mixCollHash(12345, 4));
}

test "hashOrdered is order-dependent" {
    const a = [_]u32{ hashInt(1), hashInt(2) };
    const b = [_]u32{ hashInt(2), hashInt(1) };
    try testing.expect(hashOrdered(&a) != hashOrdered(&b));
}

test "hashUnordered is order-independent" {
    const a = [_]u32{ hashInt(1), hashInt(2), hashInt(3) };
    const b = [_]u32{ hashInt(3), hashInt(1), hashInt(2) };
    try testing.expectEqual(hashUnordered(&a), hashUnordered(&b));
}

test "hashUnencodedChars matches JVM Murmur3 (clj oracle)" {
    // clj: (clojure.lang.Murmur3/hashUnencodedChars s) — UTF-16 code-unit
    // hash, JVM bit-parity (D-376). Values incl. a surrogate-pair case (𠮷 =
    // U+20BB7 → 2 UTF-16 units).
    try testing.expectEqual(@as(i32, 1118836419), @as(i32, @bitCast(hashUnencodedChars("abc"))));
    try testing.expectEqual(@as(i32, 1867108634), @as(i32, @bitCast(hashUnencodedChars("a"))));
    try testing.expectEqual(@as(i32, 0), @as(i32, @bitCast(hashUnencodedChars(""))));
    try testing.expectEqual(@as(i32, 1689409188), @as(i32, @bitCast(hashUnencodedChars("hello world"))));
    try testing.expectEqual(@as(i32, 1524218000), @as(i32, @bitCast(hashUnencodedChars("あいう"))));
    try testing.expectEqual(@as(i32, -383720716), @as(i32, @bitCast(hashUnencodedChars("𠮷野家"))));
}

test "string hashes are TOTAL over bytes that are not valid UTF-8" {
    // A cljw String is raw bytes, so these are reachable values, not abuse:
    // `(slurp "x.wasm")` produces the first one. Before nextCodepointLossy
    // each of these ABORTED the process inside Utf8View.initUnchecked's
    // iterator, which is why `(hash (slurp binary))` core-dumped the REPL.
    const bad = [_][]const u8{
        "\x00asm\x01\x00\x00\x00", // a Wasm module header
        "\xff\xfe\xfd", // never-valid lead bytes
        "\xc3", // truncated 2-byte sequence, nothing follows
        "\xe2\x82", // truncated 3-byte sequence
        "\xf0\x9f\x98", // truncated 4-byte sequence
        "ok\xffthen", // invalid byte BETWEEN valid text
        "\x80\x80", // continuation bytes with no lead
    };
    for (bad) |s| {
        // The assertion is that these RETURN at all. A regression aborts the
        // test process rather than failing it, so the value check is second.
        try testing.expectEqual(javaStringHashCode(s), javaStringHashCode(s));
        try testing.expectEqual(hashUnencodedChars(s), hashUnencodedChars(s));
        try testing.expectEqual(hashString(s), hashString(s));
    }

    // Replacement is per invalid BYTE, so a longer invalid run stays
    // distinguishable rather than collapsing to one replacement char.
    try testing.expect(javaStringHashCode("\xff") != javaStringHashCode("\xff\xff"));

    // Valid UTF-8 is untouched: the oracle value below still holds.
    try testing.expectEqual(@as(i32, 1118836419), @as(i32, @bitCast(hashUnencodedChars("abc"))));
}
