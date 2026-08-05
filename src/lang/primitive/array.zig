// SPDX-License-Identifier: EPL-2.0
//! Java-array primitives — the Layer-1 host surface over
//! `runtime/collection/java_array.zig` (ADR-0105 / D-287).
//!
//! Only the irreducible host operations live here: `__array-make` (sized +
//! init-filled), `aget` (2-arg), `aset` (3-arg), `alength`, `aclone`,
//! `array?`. The full clojure.core surface (object-array / int-array /
//! byte-array / make-array / to-array / into-array / aset-* / amap / areduce /
//! multi-dim aget+aset) is composed from these in `core.clj`, where seq
//! walking + per-type init defaults + byte/short/char wrap are idiomatic and
//! the seq fns already handle GC rooting (F-009 layering).

const Value = @import("../../runtime/value/value.zig").Value;
const Runtime = @import("../../runtime/runtime.zig").Runtime;
const env_mod = @import("../../runtime/env.zig");
const Env = env_mod.Env;
const error_mod = @import("../../runtime/error/info.zig");
const error_catalog = @import("../../runtime/error/catalog.zig");
const SourceLocation = error_mod.SourceLocation;
const java_array = @import("../../runtime/collection/java_array.zig");

fn requireArray(v: Value, fn_name: []const u8, loc: SourceLocation) !void {
    if (v.tag() != .array)
        return error_catalog.raise(.type_arg_invalid, loc, .{
            .fn_name = fn_name,
            .expected = "an array",
            .actual = @tagName(v.tag()),
        });
}

fn asIndex(v: Value, fn_name: []const u8, loc: SourceLocation) !i64 {
    if (v.tag() != .integer)
        return error_catalog.raise(.type_arg_invalid, loc, .{
            .fn_name = fn_name,
            .expected = "an integer index",
            .actual = @tagName(v.tag()),
        });
    return v.asInteger();
}

/// `(rt/__array-make size init-val)` — allocate a `size`-element array with
/// every slot set to `init-val`. The clj per-constructor default (0 / 0.0 /
/// false / \space / nil) is chosen by the core.clj caller (F-011).
fn arrayMakeFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("__array-make", args, 2, loc);
    const n = try asIndex(args[0], "__array-make", loc);
    if (n < 0)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "__array-make", .expected = "a non-negative size", .actual = "negative" });
    return java_array.make(rt, @intCast(n), args[1]);
}

/// `(aget array idx & idxs)` — element read, multi-dim by recursion exactly
/// as clj's variadic `aget` composes: `(aget a i j)` reads the nested array
/// at `i`, then `j` within it. Implemented directly in the builtin rather
/// than as a core.clj variadic (the D-446 barrier sketched that shape) so the
/// hot 2-arg path stays a single builtin call.
fn agetFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArityMin("aget", args, 2, loc);
    var v = args[0];
    for (args[1..]) |idx| {
        try requireArray(v, "aget", loc);
        v = try java_array.aget(v, try asIndex(idx, "aget", loc), "aget", loc);
    }
    return v;
}

/// `(aset array idx val)` — 3-arg in-place write, returns `val`.
fn asetFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArityMin("aset", args, 3, loc);
    // `(aset a i j … v)`: every arg but the last two walks into a nested
    // array; the final pair is the ordinary element store, which returns the
    // stored value as clj does.
    var v = args[0];
    for (args[1 .. args.len - 2]) |idx| {
        try requireArray(v, "aset", loc);
        v = try java_array.aget(v, try asIndex(idx, "aset", loc), "aset", loc);
    }
    try requireArray(v, "aset", loc);
    return java_array.aset(v, try asIndex(args[args.len - 2], "aset", loc), args[args.len - 1], "aset", loc);
}

fn alengthFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("alength", args, 1, loc);
    try requireArray(args[0], "alength", loc);
    return Value.initInteger(@intCast(java_array.alength(args[0])));
}

fn acloneFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("aclone", args, 1, loc);
    try requireArray(args[0], "aclone", loc);
    return java_array.aclone(rt, args[0]);
}

fn arrayQFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("array?", args, 1, loc);
    return Value.initBoolean(args[0].tag() == .array);
}

const Entry = struct { name: []const u8, f: *const fn (*Runtime, *Env, []const Value, SourceLocation) anyerror!Value };

const ENTRIES = [_]Entry{
    .{ .name = "__array-make", .f = &arrayMakeFn },
    .{ .name = "aget", .f = &agetFn },
    .{ .name = "aset", .f = &asetFn },
    .{ .name = "alength", .f = &alengthFn },
    .{ .name = "aclone", .f = &acloneFn },
    .{ .name = "array?", .f = &arrayQFn },
};

pub fn register(env: *Env, rt_ns: *env_mod.Namespace) !void {
    for (ENTRIES) |it| {
        _ = try env.intern(rt_ns, it.name, Value.initBuiltinFn(it.f), null);
    }
}
