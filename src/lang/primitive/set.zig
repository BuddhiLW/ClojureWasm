// SPDX-License-Identifier: EPL-2.0
//! `clojure.set/` namespace surface + the set/map constructors.
//!
//! The Group A + B vars (`union` / `intersection` / `difference` /
//! `subset?` / `superset?` / `rename-keys` / `map-invert`) live as
//! pure-Clojure Pattern A defns in `src/lang/clj/clojure/set.clj`
//! per ADR-0033 D3 + v5 §8.2. This file ships only the variadic
//! constructors:
//!
//! - `hash-set` — `(hash-set & xs)`. (The `#{...}` reader literal has
//!   its own `.set` Form variant, so it does not route through here.)
//! - `hash-map` / `array-map` — `(hash-map & kvs)`. (The `{...}`
//!   literal likewise has its own Form variant.)
//!
//! Group C (`select` / `project` / `index` / `rename` / `join`,
//! relational ops over sets-of-maps) is not yet implemented; it is
//! tracked by D-061.

const std = @import("std");
const Value = @import("../../runtime/value/value.zig").Value;
const Runtime = @import("../../runtime/runtime.zig").Runtime;
const env_mod = @import("../../runtime/env.zig");
const Env = env_mod.Env;
const error_mod = @import("../../runtime/error/info.zig");
const SourceLocation = error_mod.SourceLocation;
const error_catalog = @import("../../runtime/error/catalog.zig");
const dispatch = @import("../../runtime/dispatch.zig");
const set_collection = @import("../../runtime/collection/set.zig");
const map_collection = @import("../../runtime/collection/map.zig");

/// `(hash-set & xs)` — construct a set from variadic args. Empty
/// arg list returns the empty-set singleton. Each arg is conj-ed
/// in order (idempotent — duplicates collapse).
pub fn hashSet(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    _ = loc;
    var s = set_collection.empty();
    for (args, 0..) |a, i| {
        // JVM ##NaN is one shared boxed reader constant: two literal args to
        // hash-set are identical objects even though NaN is not = to itself.
        // cljw's unboxed floats have no object identity; preserve that literal
        // case here without changing contains?/assoc's IEEE key equality.
        if (a.tag() == .float and std.math.isNan(a.asFloat())) {
            var prior_nan = false;
            for (args[0..i]) |prior| {
                if (prior.tag() == .float and std.math.isNan(prior.asFloat())) {
                    prior_nan = true;
                    break;
                }
            }
            if (prior_nan) continue;
        }
        s = try set_collection.conj(rt, s, a);
    }
    return s;
}

/// `(hash-map & kvs)` — construct a map from variadic key/value pairs.
/// Odd argument count raises `map_literal_arity_odd` (matches the
/// JVM `IllegalArgumentException`). Empty arg list returns the
/// empty-map singleton.
pub fn hashMap(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    if (args.len % 2 != 0)
        return error_catalog.raise(.map_literal_arity_odd, loc, .{});
    var m = map_collection.empty();
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        const key = args[i];
        if (key.tag() == .float and std.math.isNan(key.asFloat())) {
            // Repeated ##NaN is one JVM reader constant. Skip all but the
            // last occurrence (runtime dissoc cannot locate a NaN key).
            var later = i + 2;
            var repeated = false;
            while (later < args.len) : (later += 2) {
                const next = args[later];
                if (next.tag() == .float and std.math.isNan(next.asFloat())) {
                    repeated = true;
                    break;
                }
            }
            if (repeated) continue;
        }
        m = try map_collection.assoc(rt, m, key, args[i + 1]);
    }
    return m;
}

// --- registration ---

const Entry = struct {
    name: []const u8,
    f: dispatch.BuiltinFn,
};

const RT_ENTRIES = [_]Entry{
    .{ .name = "hash-set", .f = &hashSet },
    .{ .name = "hash-map", .f = &hashMap },
    // array-map: a cljw map starts array-backed (insertion-ordered) for ≤8
    // entries, so for the realistic small-map surface array-map ≡ hash-map's
    // output. (Residual: clj's array-map never hash-promotes; cljw promotes
    // past 8 entries — a >8-entry array-map is rare.)
    .{ .name = "array-map", .f = &hashMap },
};

/// Register `hash-set` / `hash-map` into `rt/` (so they are user-
/// callable unqualified after `(refer 'rt)` into `user/`) and ensure
/// the `clojure.set` namespace exists for the .clj loader to enter.
/// The Group A + B vars themselves are registered by evaluating
/// `src/lang/clj/clojure/set.clj` at bootstrap.
pub fn register(env: *Env) !void {
    const core_ns = env.findNs("clojure.core") orelse return error.ClojureCoreNamespaceMissing;
    for (RT_ENTRIES) |it| {
        _ = try env.intern(core_ns, it.name, Value.initBuiltinFn(it.f), null);
    }
    _ = try env.findOrCreateNs("clojure.set");
}
