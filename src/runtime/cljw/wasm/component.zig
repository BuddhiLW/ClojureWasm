// SPDX-License-Identifier: EPL-2.0
//! EXPERIMENT (D-404 / ADR-0135) — Wasm component introspection + typed invoke.
//! `(wasm/component-exports "p.wasm")` lists a component's typed func exports;
//! `(wasm/component-invoke "p.wasm" "func" & args)` lowers cljw values per the
//! export's WIT signature, invokes through zwasm's Canonical ABI, and lifts the
//! result tree back to Clojure data per the ADR-0135 mapping.
//!
//! EXPLORATION MODE: rides the LOCAL relative-path zwasm dep (build.zig.zon
//! flip, uncommitted, push-suppressed). Adopts the finished-form zwasm CM-API
//! (pin 5795c3d0): `comp.open`→`Opened` (REQ-1), `resolveFuncSig`/`WitType`
//! (REQ-3, replaces the old hand-rolled TypeCtx), label-carrying enum/variant/
//! flags values (REQ-2). The finished form (require-a-component → one Var per
//! export) lands per D-404 once stable.
//!
//! Backend: impl-only
//! Impl deps: none
//! Clojure peer: wasm/component-exports, wasm/component-invoke

const std = @import("std");
const zwasm = @import("zwasm");
const Runtime = @import("../../runtime.zig").Runtime;
const Env = @import("../../env.zig").Env;
const Value = @import("../../value/value.zig").Value;
const error_catalog = @import("../../error/catalog.zig");
const SourceLocation = @import("../../error/info.zig").SourceLocation;
const string_mod = @import("../../collection/string.zig");
const vector_mod = @import("../../collection/vector.zig");
const map_mod = @import("../../collection/map.zig");
const set_mod = @import("../../collection/set.zig");
const keyword_mod = @import("../../keyword.zig");
const file_io = @import("../../file_io.zig");
const host_instance = @import("../../host_instance.zig");
const marshal = @import("marshal.zig");
const promote = @import("../../numeric/promote.zig");
const big_int = @import("../../numeric/big_int.zig");
const type_descriptor = @import("../../type_descriptor.zig");
const mark_sweep = @import("../../gc/mark_sweep.zig");
const gc_heap_mod = @import("../../gc/gc_heap.zig");

const comp = zwasm.feature.component.host;
const ctypes = zwasm.feature.component.types;
const ComponentValue = comp.ComponentValue;
const WitType = comp.WitType;
const WasiHost = zwasm.wasi.host.Host;

/// Read + FS-jail-resolve a component path argument.
fn readComponentBytes(rt: *Runtime, path_val: Value, loc: SourceLocation) anyerror![]const u8 {
    if (!path_val.isString())
        return error_catalog.raise(.wasm_path_invalid, loc, .{});
    const path = string_mod.asString(path_val);
    // ADR-0158 (D-404 Impl D): a `cljw build` binary bakes every static
    // `:require`d component's bytes into an embedded table keyed by the
    // resolved path. Serve from memory before any FS read so the binary is
    // self-contained. A genuinely dynamic `(wasm/load runtime-path)` whose path
    // was not embedded misses here and falls through to the FS jail load.
    for (rt.embedded_components) |c| {
        if (std.mem.eql(u8, c.path, path)) return rt.gpa.dupe(u8, c.bytes);
    }
    const jailed = file_io.jailResolve(rt.gpa, rt.fs_jail_root, path) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.FsJailEscape => return error_catalog.raise(.fs_jail_escape, loc, .{ .fn_name = "wasm/component", .path = path }),
    };
    defer if (jailed) |j| rt.gpa.free(j);
    const open_path = jailed orelse path;
    return file_io.readAll(rt.io, rt.gpa, open_path) catch
        error_catalog.raise(.wasm_load_read_failed, loc, .{ .path = path });
}

/// Render a `WitType` human-readably for the introspection probe:
/// "string", "u32", "record{xs: list<u32>, label: string}", "enum{a, b}", …
fn writeWitType(w: *std.Io.Writer, ty: WitType) anyerror!void {
    switch (ty) {
        .prim => |p| try w.writeAll(@tagName(p)),
        .list => |elem| {
            try w.writeAll("list<");
            try writeWitType(w, elem.*);
            try w.writeAll(">");
        },
        .record => |fields| {
            try w.writeAll("record{");
            for (fields, 0..) |f, i| {
                if (i > 0) try w.writeAll(", ");
                try w.print("{s}: ", .{f.name});
                try writeWitType(w, f.ty);
            }
            try w.writeAll("}");
        },
        .tuple => |types| {
            try w.writeAll("tuple<");
            for (types, 0..) |t, i| {
                if (i > 0) try w.writeAll(", ");
                try writeWitType(w, t);
            }
            try w.writeAll(">");
        },
        .variant => |cases| {
            try w.writeAll("variant{");
            for (cases, 0..) |c, i| {
                if (i > 0) try w.writeAll(", ");
                try w.writeAll(c.name);
            }
            try w.writeAll("}");
        },
        .enum_ => |labels| {
            try w.writeAll("enum{");
            for (labels, 0..) |l, i| {
                if (i > 0) try w.writeAll(", ");
                try w.writeAll(l);
            }
            try w.writeAll("}");
        },
        .option => |inner| {
            try w.writeAll("option<");
            try writeWitType(w, inner.*);
            try w.writeAll(">");
        },
        .result => |r| {
            try w.writeAll("result<");
            if (r.ok) |ok| try writeWitType(w, ok.*) else try w.writeAll("_");
            try w.writeAll(", ");
            if (r.err) |er| try writeWitType(w, er.*) else try w.writeAll("_");
            try w.writeAll(">");
        },
        .flags => |labels| {
            try w.writeAll("flags{");
            for (labels, 0..) |l, i| {
                if (i > 0) try w.writeAll(", ");
                try w.writeAll(l);
            }
            try w.writeAll("}");
        },
        .own => |i| try w.print("own<{d}>", .{i}),
        .borrow => |i| try w.print("borrow<{d}>", .{i}),
    }
}

fn witTypeName(alloc: std.mem.Allocator, ty: WitType) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    errdefer aw.deinit();
    try writeWitType(&aw.writer, ty);
    return aw.toOwnedSlice();
}

/// Open a component into a unified `Opened` handle (zwasm REQ-1 `comp.open`
/// auto-selects single-module vs WASI-P2 graph). The WasiHost is caller-owned
/// and must outlive `Opened` (the graph path borrows it); both are freed by the
/// caller's `defer`s in LIFO order (opened first, then host).
fn openComponent(rt: *Runtime, engine: *zwasm.Engine, host: *WasiHost, bytes: []const u8, loc: SourceLocation) anyerror!comp.Opened {
    host.* = WasiHost.init(rt.gpa) catch return error_catalog.raise(.wasm_load_failed, loc, .{});
    errdefer host.deinit();
    host.io = rt.io;
    return comp.open(engine, rt.gpa, bytes, host, .{}) catch
        error_catalog.raise(.wasm_load_failed, loc, .{});
}

/// `(wasm/component-exports "p.wasm")` — vector of
/// `{:name "greet" :params [["name" "string"] …] :result "string"}` maps,
/// straight from the component's self-describing type section.
pub fn componentExportsFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("wasm/component-exports", args, 1, loc);
    const bytes = try readComponentBytes(rt, args[0], loc);
    defer rt.gpa.free(bytes);

    var engine = zwasm.Engine.init(rt.gpa, .{}) catch
        return error_catalog.raise(.wasm_load_failed, loc, .{});
    defer engine.deinit();
    var host: WasiHost = undefined;
    var opened = try openComponent(rt, &engine, &host, bytes, loc);
    defer host.deinit();
    defer opened.deinit();

    const funcs = try opened.exportedFuncs(rt.gpa);
    defer ctypes.TypeInfo.freeExportedFuncs(rt.gpa, funcs);

    var type_arena = std.heap.ArenaAllocator.init(rt.gpa);
    defer type_arena.deinit();

    var out = vector_mod.empty();
    for (funcs) |f| {
        const sig = (opened.resolveFuncSig(type_arena.allocator(), f.name) catch null) orelse continue;
        var m = map_mod.empty();
        m = try map_mod.assoc(rt, m, try keyword_mod.intern(rt, null, "name"), try string_mod.alloc(rt, f.name));
        var params = vector_mod.empty();
        for (sig.params) |p| {
            const tn = try witTypeName(rt.gpa, p.ty);
            defer rt.gpa.free(tn);
            const pair = try vector_mod.fromSlice(rt, &.{
                try string_mod.alloc(rt, p.name),
                try string_mod.alloc(rt, tn),
            });
            params = try vector_mod.conj(rt, params, pair);
        }
        m = try map_mod.assoc(rt, m, try keyword_mod.intern(rt, null, "params"), params);
        const res: Value = if (sig.result) |rty| blk: {
            const tn = try witTypeName(rt.gpa, rty);
            defer rt.gpa.free(tn);
            break :blk try string_mod.alloc(rt, tn);
        } else Value.nil_val;
        m = try map_mod.assoc(rt, m, try keyword_mod.intern(rt, null, "result"), res);
        out = try vector_mod.conj(rt, out, m);
    }
    return out;
}

/// A `u64` above `maxInt(i64)` exactly, as a BigInt. ADR-0135's table already
/// promised this ("u64/s64 may promote to BigInt at the f64 edge, F-005"); the
/// code did a narrowing `@intCast` instead, which panics in ReleaseSafe.
fn bigFromU64(rt: *Runtime, n: u64) !Value {
    var m = try std.math.big.int.Managed.init(rt.gc.infra);
    defer m.deinit();
    try m.set(n);
    return try big_int.allocFromManaged(rt, &m, .bigint);
}

/// Lower a cljw Value into a `ComponentValue` directed by the WIT param type
/// (the ADR-0135 table, lower direction). Compound nodes allocate on `scratch`
/// (an arena the invoke owns); strings borrow the GC string. enum/variant are
/// passed by ORDINAL (zwasm REQ-2: the lower path is label-less; a cljw keyword
/// maps to its ordinal via the WitType labels here).
fn lower(rt: *Runtime, scratch: std.mem.Allocator, v: Value, ty: WitType, loc: SourceLocation) anyerror!ComponentValue {
    switch (ty) {
        .prim => |p| return switch (p) {
            .bool => .{ .bool = v.isTruthy() },
            .string => blk: {
                if (!v.isString()) return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "wasm/component-invoke", .actual = @tagName(v.tag()) });
                break :blk .{ .string = string_mod.asString(v) };
            },
            // Range-checked through the SAME helper `wasm/call` uses
            // (`marshal.coerceInt`). These were bare `@intCast`s, which in
            // ReleaseSafe — the shipped config — is a process-killing safety
            // panic on out-of-range caller data, not a catchable error. The
            // core-module surface next door had always checked; the component
            // surface never inherited it.
            .u8 => .{ .u8 = try marshal.coerceInt(v, u8, loc) },
            .s8 => .{ .s8 = try marshal.coerceInt(v, i8, loc) },
            .u16 => .{ .u16 = try marshal.coerceInt(v, u16, loc) },
            .s16 => .{ .s16 = try marshal.coerceInt(v, i16, loc) },
            .u32 => .{ .u32 = try marshal.coerceInt(v, u32, loc) },
            .s32 => .{ .s32 = try marshal.coerceInt(v, i32, loc) },
            .u64 => .{ .u64 = try marshal.coerceInt(v, u64, loc) },
            .s64 => .{ .s64 = try marshal.coerceInt(v, i64, loc) },
            .f32 => .{ .f32 = @floatCast(v.asFloat()) },
            .f64 => .{ .f64 = v.asFloat() },
            .char => .{ .char = try marshal.coerceInt(v, u21, loc) },
            else => error_catalog.raise(.feature_not_supported, loc, .{ .name = "wasm/component-invoke: this WIT param type" }),
        },
        .record => |fields| {
            const mt = v.tag();
            if (mt != .array_map and mt != .hash_map)
                return error_catalog.raise(.wasm_opts_invalid, loc, .{ .detail = "a WIT record param expects a map" });
            const out = try scratch.alloc(ComponentValue.Field, fields.len);
            for (fields, 0..) |f, i| {
                const kw = try keyword_mod.intern(rt, null, f.name);
                const fv = map_mod.get(v, kw) catch Value.nil_val;
                out[i] = .{ .name = f.name, .value = try lower(rt, scratch, fv, f.ty, loc) };
            }
            return .{ .record = out };
        },
        .list => |elem| {
            if (v.tag() != .vector)
                return error_catalog.raise(.wasm_opts_invalid, loc, .{ .detail = "a WIT list param expects a vector" });
            const n = vector_mod.count(v);
            const items = try scratch.alloc(ComponentValue, n);
            var i: u32 = 0;
            while (i < n) : (i += 1) items[i] = try lower(rt, scratch, vector_mod.nth(v, i), elem.*, loc);
            return .{ .list = items };
        },
        .tuple => |types| {
            if (v.tag() != .vector or vector_mod.count(v) != types.len)
                return error_catalog.raise(.wasm_opts_invalid, loc, .{ .detail = "a WIT tuple param expects a vector of the tuple arity" });
            const items = try scratch.alloc(ComponentValue, types.len);
            for (types, 0..) |t, i| items[i] = try lower(rt, scratch, vector_mod.nth(v, @intCast(i)), t, loc);
            return .{ .tuple = items };
        },
        .option => |inner| {
            if (v.isNil()) return .{ .option = null };
            const boxed = try scratch.create(ComponentValue);
            boxed.* = try lower(rt, scratch, v, inner.*, loc);
            return .{ .option = boxed };
        },
        .enum_ => |labels| {
            const idx = try enumOrdinal(v, labels, loc);
            return .{ .@"enum" = .{ .index = idx } };
        },
        .flags => |labels| {
            // a set of keywords → the bit-set per the type's label order.
            var bits: u32 = 0;
            for (labels, 0..) |l, i| {
                const kw = try keyword_mod.intern(rt, null, l);
                if (set_mod.contains(v, kw) catch false) bits |= (@as(u32, 1) << @intCast(i));
            }
            return .{ .flags = .{ .bits = bits } };
        },
        .own => return .{ .own = try rawResourceHandle(v, loc) },
        .borrow => return .{ .borrow = try rawResourceHandle(v, loc) },
        .result, .variant => return error_catalog.raise(.feature_not_supported, loc, .{ .name = "wasm/component-invoke: result/variant param (rare on the input side)" }),
    }
}

/// Map a cljw keyword (or integer ordinal) to an enum/variant case index using
/// the WIT labels (zwasm REQ-2 input direction).
fn enumOrdinal(v: Value, labels: []const []const u8, loc: SourceLocation) anyerror!u32 {
    if (v.tag() == .keyword) {
        const name = keyword_mod.asKeyword(v).name;
        for (labels, 0..) |l, i| if (std.mem.eql(u8, l, name)) return @intCast(i);
        return error_catalog.raise(.wasm_opts_invalid, loc, .{ .detail = "unknown WIT enum/variant label" });
    }
    return @intCast(v.asInteger());
}

/// Lift a `ComponentValue` tree to Clojure data per ADR-0135. With zwasm REQ-2
/// labels the FULL mapping is value-derivable: enum→keyword, flags→set of
/// keywords, variant→tagged map, result→value|throw, record→map, option→nil|v.
/// `component_handle` (ADR-0159): when non-null (the cached `component-call`
/// path), an `own` result becomes a typed GC-resource wrapper that roots that
/// component and can be `wasm/resource-drop`'d; null (the one-shot
/// `component-invoke` path, no persistent component to own it) keeps the bare
/// integer. `borrow` is never owned, so it stays a bare integer in both.
fn lift(rt: *Runtime, cv: ComponentValue, loc: SourceLocation, component_handle: ?Value) anyerror!Value {
    return switch (cv) {
        .bool => |b| Value.initBoolean(b),
        .s8 => |n| Value.initInteger(n),
        .u8 => |n| Value.initInteger(n),
        .s16 => |n| Value.initInteger(n),
        .u16 => |n| Value.initInteger(n),
        .s32 => |n| Value.initInteger(n),
        .u32 => |n| Value.initInteger(n),
        // `Value.initInteger` silently demotes an out-of-i48 value to a LOSSY
        // float (its own doc says so), and i48 is only about +/-1.4e14 — well
        // inside what a guest can legitimately return. `promote.wrapI64` is the
        // canonical exact-i64 entry: it stays a fixnum in range and promotes to
        // a heap Long outside it, matching F-005's numeric tower.
        .s64 => |n| try promote.wrapI64(rt, n),
        // A u64 above i64's maximum has no i64 to widen to at all. The old
        // `@intCast` was a ReleaseSafe panic on GUEST-CONTROLLED data — an
        // untrusted component could kill the host by returning a large u64.
        .u64 => |n| if (n <= std.math.maxInt(i64))
            try promote.wrapI64(rt, @intCast(n))
        else
            try bigFromU64(rt, n),
        .f32 => |f| Value.initFloat(f),
        .f64 => |f| Value.initFloat(f),
        .char => |c| Value.initChar(c),
        .string => |s| try string_mod.alloc(rt, s),
        .list, .tuple => |items| blk: {
            var out = vector_mod.empty();
            for (items) |item| out = try vector_mod.conj(rt, out, try lift(rt, item, loc, component_handle));
            break :blk out;
        },
        .record => |fields| blk: {
            var m = map_mod.empty();
            for (fields) |f|
                m = try map_mod.assoc(rt, m, try keyword_mod.intern(rt, null, f.name), try lift(rt, f.value, loc, component_handle));
            break :blk m;
        },
        .option => |opt| if (opt) |p| try lift(rt, p.*, loc, component_handle) else Value.nil_val,
        .result => |r| blk: {
            if (r.is_ok) break :blk if (r.payload) |p| try lift(rt, p.*, loc, component_handle) else Value.nil_val;
            // err arm → catchable cljw exception (ADR-0135 result→throw).
            break :blk error_catalog.raise(.wasm_trap, loc, .{});
        },
        .variant => |vt| blk: {
            // {:wit/case :name :value v} — the case label (REQ-2) when present.
            var m = map_mod.empty();
            const case_kw: Value = if (vt.case_name.len > 0)
                try keyword_mod.intern(rt, null, vt.case_name)
            else
                Value.initInteger(vt.case);
            m = try map_mod.assoc(rt, m, try keyword_mod.intern(rt, "wit", "case"), case_kw);
            const payload: Value = if (vt.payload) |p| try lift(rt, p.*, loc, component_handle) else Value.nil_val;
            m = try map_mod.assoc(rt, m, try keyword_mod.intern(rt, null, "value"), payload);
            break :blk m;
        },
        .@"enum" => |e| if (e.label.len > 0)
            try keyword_mod.intern(rt, null, e.label)
        else
            Value.initInteger(e.index),
        .flags => |fl| blk: {
            // → a set of keywords (the labels whose bit is set).
            var s = set_mod.empty();
            for (fl.labels, 0..) |l, i| {
                if ((fl.bits & (@as(u32, 1) << @intCast(i))) != 0)
                    s = try set_mod.conj(rt, s, try keyword_mod.intern(rt, null, l));
            }
            break :blk s;
        },
        .own => |h| if (component_handle) |ch| try makeResourceHandle(rt, ch, h) else Value.initInteger(h),
        .borrow => |h| Value.initInteger(h),
    };
}

// === Component resource handle (ADR-0159, D-404 Impl E) ===
//
// An `own<T>` result becomes a `.host_instance` wrapper carrying its owning
// component handle (state[0], a `.host_instance` ComponentLoaded Value), the raw
// zwasm handle (state[1]), and a one-shot dropped flag (state[2]). `host_trace`
// marks state[0] so a held resource ROOTS its component (the `Opened` cannot be
// collected while a resource is reachable; java.util.Iterator cursor precedent).
// There is deliberately NO `host_finalise`: rooting only holds while the resource
// is reachable, so a same-cycle collection of the resource + its component gives
// no finaliser ordering (F-006 mark-sweep) — any drop from the resource finaliser
// could touch a freed `Opened`. Release is therefore DETERMINISTIC
// (`wasm/resource-drop` / a `with-resource` scope, where the held wrapper proves
// the component live); `componentFinalise`'s `Opened.deinit()` drains the whole
// table at component teardown as the backstop. See ADR-0159 § Divergence.

var resource_descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "cljw.wasm.Resource",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .parent = null,
    .meta = Value.nil_val,
    .host_trace = &resourceTrace,
};

/// GC-trace: mark the owning component handle Value held in state[0] (roots the
/// `ComponentLoaded` box while this resource is reachable). GC-ROOT: §H — a moving
/// GC must RELOCATE state[0], not just mark [ref: .dev/gc_rooting.md §H].
fn resourceTrace(gc_ptr: *anyopaque, state: *[host_instance.STATE_WORDS]u64) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const ch: Value = @enumFromInt(state[0]);
    if (ch.heapHeader()) |hdr| mark_sweep.mark(gc, hdr);
}

/// Wrap an `own` handle as a GC-resource value rooting `component_handle`.
fn makeResourceHandle(rt: *Runtime, component_handle: Value, handle: u32) anyerror!Value {
    return host_instance.alloc(rt, &resource_descriptor, .{ @intFromEnum(component_handle), handle, 0, 0 });
}

/// True iff `v` is a component resource wrapper.
fn isResourceHandle(v: Value) bool {
    return v.tag() == .host_instance and host_instance.asHostInstance(v).descriptor == &resource_descriptor;
}

/// Extract the raw zwasm handle from `v` for a `borrow`/`own` param: a resource
/// wrapper yields state[1] (raising if already dropped); a bare integer (the
/// one-shot path / a hand-passed handle) yields itself.
fn rawResourceHandle(v: Value, loc: SourceLocation) anyerror!u32 {
    if (isResourceHandle(v)) {
        const inst = host_instance.asHostInstance(v);
        if (inst.state[2] != 0) return error_catalog.raise(.wasm_resource_dropped, loc, .{});
        return @intCast(inst.state[1]);
    }
    return @intCast(v.asInteger());
}

/// `(wasm/resource-drop h)` — release a component `own` resource: run its guest
/// destructor via the owning component's `Opened.dropResource`, then mark the
/// wrapper dropped (one-shot; a second drop is a no-op, NOT a zwasm stale-handle
/// trap). Deterministic release per ADR-0159; the held wrapper proves the
/// component live, so the `Opened` is valid here. Returns nil.
pub fn resourceDropFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("wasm/resource-drop", args, 1, loc);
    if (!isResourceHandle(args[0]))
        return error_catalog.raise(.wasm_opts_invalid, loc, .{ .detail = "wasm/resource-drop expects a component resource handle" });
    const inst = host_instance.asHostInstance(args[0]);
    if (inst.state[2] != 0) return Value.nil_val; // already dropped — idempotent.
    const comp_handle: Value = @enumFromInt(inst.state[0]);
    if (comp_handle.tag() != .host_instance or
        host_instance.asHostInstance(comp_handle).descriptor != &component_descriptor)
        return error_catalog.raise(.wasm_opts_invalid, loc, .{ .detail = "resource handle's owning component is not a loaded component" });
    const box: *ComponentLoaded = @ptrFromInt(host_instance.asHostInstance(comp_handle).state[0]);
    box.opened.dropResource(@intCast(inst.state[1])) catch
        return error_catalog.raise(.wasm_trap, loc, .{});
    host_instance.setState(args[0], 2, 1);
    return Value.nil_val;
}

/// `(wasm/component-invoke "p.wasm" "func" & args)` — one-shot typed invoke
/// (open → resolveFuncSig → lower → invokeTyped → lift → teardown). The require
/// path will cache the instance; this is the experiment's roundtrip probe.
pub fn componentInvokeFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArityMin("wasm/component-invoke", args, 2, loc);
    if (!args[1].isString())
        return error_catalog.raise(.wasm_export_name_invalid, loc, .{});
    const bytes = try readComponentBytes(rt, args[0], loc);
    defer rt.gpa.free(bytes);

    var engine = zwasm.Engine.init(rt.gpa, .{}) catch
        return error_catalog.raise(.wasm_load_failed, loc, .{});
    defer engine.deinit();
    var host: WasiHost = undefined;
    var opened = try openComponent(rt, &engine, &host, bytes, loc);
    defer host.deinit();
    defer opened.deinit();

    // One-shot: no persistent component to own an `own` result → null handle
    // (the `own` lifts to a bare integer; resource ownership needs component-call).
    return invokeOnOpened(rt, &opened, string_mod.asString(args[1]), args[2..], loc, null);
}

/// resolveFuncSig → lower args → invokeTyped → lift result, on an already-open
/// `Opened`. Shared by the one-shot `component-invoke` and the handle-based
/// `component-call` (the latter persists the Opened across calls).
/// `component_handle` (ADR-0159): the cached component's `.host_instance` Value
/// for `component-call`, so an `own` result wraps into a GC-resource rooting it;
/// null for the one-shot path.
fn invokeOnOpened(rt: *Runtime, opened: *comp.Opened, fname: []const u8, call_args: []const Value, loc: SourceLocation, component_handle: ?Value) anyerror!Value {
    var arena = std.heap.ArenaAllocator.init(rt.gpa);
    defer arena.deinit();
    const sig = (opened.resolveFuncSig(arena.allocator(), fname) catch null) orelse
        return error_catalog.raise(.wasm_export_not_found, loc, .{ .name = fname });
    if (call_args.len != sig.params.len)
        return error_catalog.raise(.wasm_arity_mismatch, loc, .{ .name = fname, .expected = sig.params.len, .actual = call_args.len });

    const in = try arena.allocator().alloc(ComponentValue, call_args.len);
    for (call_args, sig.params, 0..) |a, p, i| in[i] = try lower(rt, arena.allocator(), a, p.ty, loc);

    const out = opened.invokeTyped(fname, in, rt.gpa) catch
        return error_catalog.raise(.wasm_trap, loc, .{});
    if (out) |o| {
        defer o.deinit(rt.gpa);
        return try lift(rt, o, loc, component_handle);
    }
    return Value.nil_val;
}

// ---------------------------------------------------------------------------
// Instance caching (D-404 / ADR-0135 substrate) — REQ-7 (zwasm 33e0100c).
//
// `comp.open`'s `Opened` now OWNS a copy of the component bytes, so a host can
// cache it at a stable address and call across time (the load buffer is freed
// immediately after open). This was the REQ-7 blocker: pre-fix, the Opened
// borrowed the caller's bytes, so a cached handle's export names dangled and
// `resolveFuncSig` returned null. The cache is the substrate for
// require-a-component (one Var per export) + resource chains (constructor →
// method own-handle), which the one-shot `component-invoke` cannot express.
// ---------------------------------------------------------------------------

/// A long-lived opened component behind a `(wasm/load-component …)` handle.
/// `engine`/`host` are heap-stable (the WASI-P2 graph borrows `host`); `opened`
/// is stored by value and is self-contained post-REQ-7. Torn down opened → host
/// → engine (LIFO) by the host_instance finaliser.
const ComponentLoaded = struct {
    engine: *zwasm.Engine,
    host: *WasiHost,
    opened: comp.Opened,
};

/// `.host_instance` finaliser for a component handle: state[0] is the
/// `*ComponentLoaded`. Frees the zwasm triple in LIFO order. No-GC-trace: every
/// field lives in zwasm's separate space (F-006), so the descriptor sets no
/// `host_trace`.
fn componentFinalise(infra: std.mem.Allocator, state: *[host_instance.STATE_WORDS]u64) void {
    const box: *ComponentLoaded = @ptrFromInt(state[0]);
    box.opened.deinit();
    box.host.deinit();
    box.engine.deinit();
    infra.destroy(box.host);
    infra.destroy(box.engine);
    infra.destroy(box);
}

var component_descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "cljw.wasm.Component",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .parent = null,
    .meta = Value.nil_val,
    .host_finalise = &componentFinalise,
};

/// `(wasm/load-component "p.wasm")` → a cached component handle. Opens once,
/// frees the load buffer immediately (REQ-7), and keeps the `Opened` alive
/// behind a GC-finalised host_instance for `(wasm/component-call …)` to invoke
/// across time.
pub fn loadComponentFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("wasm/load-component", args, 1, loc);
    const bytes = try readComponentBytes(rt, args[0], loc);
    defer rt.gpa.free(bytes); // REQ-7: the Opened owns its bytes — drop the load buffer now.

    const engine = try rt.gpa.create(zwasm.Engine);
    errdefer rt.gpa.destroy(engine);
    engine.* = zwasm.Engine.init(rt.gpa, .{}) catch
        return error_catalog.raise(.wasm_load_failed, loc, .{});
    errdefer engine.deinit();

    const host = try rt.gpa.create(WasiHost);
    errdefer rt.gpa.destroy(host);
    var opened = try openComponent(rt, engine, host, bytes, loc);
    // errdefer order: opened.deinit must run BEFORE host.deinit (it borrows host),
    // so register host.deinit FIRST (runs last under LIFO).
    errdefer host.deinit();
    errdefer opened.deinit();

    const box = try rt.gpa.create(ComponentLoaded);
    errdefer rt.gpa.destroy(box);
    box.* = .{ .engine = engine, .host = host, .opened = opened };
    return host_instance.alloc(rt, &component_descriptor, .{ @intFromPtr(box), 0, 0, 0 });
}

/// `(wasm/component-call handle "func" & args)` — typed invoke against a cached
/// component handle. Same lower → invokeTyped → lift roundtrip as the one-shot
/// `component-invoke`, but the `Opened` persists across calls (REQ-7), so an
/// `own`-handle returned by one call (a resource constructor) stays valid as the
/// receiver of the next (a method) — the resource-chain the one-shot path cannot
/// express.
pub fn componentCallFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArityMin("wasm/component-call", args, 2, loc);
    if (args[0].tag() != .host_instance or
        host_instance.asHostInstance(args[0]).descriptor != &component_descriptor)
        return error_catalog.raise(.wasm_opts_invalid, loc, .{ .detail = "wasm/component-call expects a (wasm/load-component …) handle" });
    if (!args[1].isString())
        return error_catalog.raise(.wasm_export_name_invalid, loc, .{});
    const box: *ComponentLoaded = @ptrFromInt(host_instance.asHostInstance(args[0]).state[0]);
    // Pass the component handle so an `own` result wraps into a GC-resource that
    // roots THIS component (ADR-0159).
    return invokeOnOpened(rt, &box.opened, string_mod.asString(args[1]), args[2..], loc, args[0]);
}

const testing = std.testing;

/// The Fixture shape used across `runtime/` unit tests (cf. `numeric/promote.zig`).
const TestFixture = struct {
    threaded: std.Io.Threaded,
    rt: Runtime,

    fn init() TestFixture {
        var fix: TestFixture = .{
            .threaded = std.Io.Threaded.init(testing.allocator, .{}),
            .rt = undefined,
        };
        fix.rt = Runtime.init(fix.threaded.io(), testing.allocator);
        return fix;
    }
    fn deinit(self: *TestFixture) void {
        self.rt.deinit();
        self.threaded.deinit();
    }
};

test "lifting a u64 above i64's max is exact, not a ReleaseSafe panic" {
    var fix = TestFixture.init();
    defer fix.deinit();

    // The old code was `Value.initInteger(@intCast(n))`. In ReleaseSafe — the
    // SHIPPED config — that cast is a process-killing safety panic, and `n`
    // here is data the GUEST chose: an untrusted component could take the host
    // down by returning a large u64.
    const big: u64 = std.math.maxInt(u64);
    const v = try bigFromU64(&fix.rt, big);
    try testing.expect(v.tag() == .big_int);

    // Exact, not rounded: 18446744073709551615 must survive as itself.
    var buf: [64]u8 = undefined;
    const m = big_int.asManaged(v);
    const s = try m.toString(testing.allocator, 10, .lower);
    defer testing.allocator.free(s);
    _ = &buf;
    try testing.expectEqualStrings("18446744073709551615", s);
}

test "lifting an s64 outside i48 stays exact instead of demoting to a lossy float" {
    var fix = TestFixture.init();
    defer fix.deinit();

    // `Value.initInteger` silently demotes an out-of-i48 value to a float (its
    // own doc comment says so), and i48 tops out around 1.4e14 — well inside
    // what a guest can legitimately return. Route through the canonical
    // exact-i64 entry instead.
    const n: i64 = std.math.maxInt(i64);
    const v = try promote.wrapI64(&fix.rt, n);
    try testing.expect(v.tag() != .float);

    const m = big_int.asManaged(v);
    const s = try m.toString(testing.allocator, 10, .lower);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("9223372036854775807", s);
}

test "lowering an out-of-range integer is a catchable error, not a panic" {
    // 300 does not fit a WIT `u8`. The component path used a bare `@intCast`
    // and panicked; it now shares `wasm/call`'s range check, whose own doc
    // states the invariant the component path was breaking — "no host crash on
    // caller data".
    const loc: SourceLocation = .{};
    try testing.expectError(
        error.ValueError,
        marshal.coerceInt(Value.initInteger(300), u8, loc),
    );
    // …and an in-range value still passes.
    try testing.expectEqual(@as(u8, 200), try marshal.coerceInt(Value.initInteger(200), u8, loc));
}
