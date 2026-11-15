// SPDX-License-Identifier: EPL-2.0
//! Native map/filter/remove/take transducer closures. Applying an xform
//! allocates a fresh reducing function, so state belongs to that reduction.
//! Init and completion delegate unchanged; map alone accepts multiple inputs.
//! All user callables use invokeCallable, including mixed interpreted xforms.
//!
//! ## Backend: impl-only (no surface delegation)
//! Impl deps: Function native closures, higher_order.invokeCallable, math, reduced
//! Clojure peer: map/filter/remove/take transducer arities (core.clj)

const Value = @import("../../runtime/value/value.zig").Value;
const Runtime = @import("../../runtime/runtime.zig").Runtime;
const env_mod = @import("../../runtime/env.zig");
const Env = env_mod.Env;
const SourceLocation = @import("../../runtime/error/info.zig").SourceLocation;
const error_catalog = @import("../../runtime/error/catalog.zig");
const root_set = @import("../../runtime/gc/root_set.zig");
const reduced = @import("../../runtime/collection/reduced.zig");
const volatile_cell = @import("../../runtime/volatile.zig");
const tree_walk = @import("../../eval/backend/tree_walk.zig");
const higher_order = @import("higher_order.zig");
const invokeCallable = higher_order.invokeCallable;
const math = @import("math.zig");
const eval_budget = @import("../../runtime/concurrency/eval_budget.zig");
const safepoint = @import("../../runtime/concurrency/safepoint.zig");
const runtime_thread = @import("../../runtime/concurrency/runtime_thread.zig");

const Kind = enum(i64) { map, filter, remove, take };

fn captures(f: Value) []Value {
    return f.decodePtr(*tree_walk.Function).closure_bindings.?;
}

// GC-ROOT: native activations retain their callee, inputs, mapped result and
// the invocation-local decremented take count across arbitrary user callbacks.
const Roots = struct {
    values: [3]Value = @splat(Value.nil_val),
    sp: u16 = 3,
    frame: root_set.EvalFrame = undefined,

    fn push(self: *Roots, f: Value, args: []const Value) void {
        self.frame = .{
            .stack = &self.values,
            .sp = &self.sp,
            .locals = &.{},
            .constants = args,
            .callee = f,
            .parent = root_set.eval_frame_head,
        };
        root_set.eval_frame_head = &self.frame;
    }
    fn checkpoint(_: *Roots, rt: *Runtime, loc: SourceLocation) !void {
        // No evaluator entry separates native stages, so retain its measured
        // stack limit, budget and GC rendezvous here after publishing roots.
        const sp = @frameAddress();
        const top = &root_set.conservative_stack_top;
        if (top.* == 0 or sp > top.*) {
            top.* = sp;
        } else if (top.* - sp > runtime_thread.STACK_BUDGET_BYTES) {
            return error_catalog.raise(.stack_overflow, loc, .{ .max = runtime_thread.STACK_BUDGET_BYTES });
        }
        safepoint.poll();
        if (eval_budget.current) |budget| try budget.tick(rt.io);
    }
    fn pop(self: *Roots) void {
        root_set.eval_frame_head = self.frame.parent;
    }
};

fn xformCall(rt: *Runtime, env: *Env, f: Value, args: []const Value, loc: SourceLocation, _: tree_walk.RestMode) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("transducer", args, 1, loc);
    var roots: Roots = .{};
    roots.push(f, args);
    defer roots.pop();
    try roots.checkpoint(rt, loc);
    const caps = captures(f);
    // [kind, operand, downstream]. take retains the existing volatile's
    // acquire/release visibility, not an unsynchronized mutable capture.
    const kind: Kind = @enumFromInt(caps[0].asInteger());
    roots.values[0] = if (kind == .take) try volatile_cell.alloc(rt, caps[1]) else caps[1];
    return tree_walk.allocNativeFunction(rt, &.{ caps[0], roots.values[0], args[0] }, if (kind == .map) 2 else null, &stepCall);
}

// PERF: run each core transducer step in Zig, not vm.eval; downstream native
// closures use invokeCallable's direct native dispatch [refs: O-111].
fn stepCall(rt: *Runtime, env: *Env, f: Value, args: []const Value, loc: SourceLocation, rest_mode: tree_walk.RestMode) anyerror!Value {
    const caps = captures(f);
    const kind: Kind = @enumFromInt(caps[0].asInteger());
    if (args.len > 2 and kind != .map)
        return error_catalog.raise(.arity_not_expected, loc, .{ .fn_name = "transducer step", .expected = 2, .got = args.len });
    var roots: Roots = .{};
    roots.push(f, args);
    defer roots.pop();
    try roots.checkpoint(rt, loc);
    const downstream = caps[2];
    if (args.len < 2) return invokeCallable(rt, env, downstream, args, loc);
    switch (kind) {
        .map => {
            roots.values[0] = if (rest_mode == .bind_direct)
                try higher_order.applyFn(rt, env, &.{ caps[1], args[1], args[2] }, loc)
            else
                try invokeCallable(rt, env, caps[1], args[1..], loc);
            return invokeCallable(rt, env, downstream, &.{ args[0], roots.values[0] }, loc);
        },
        .filter, .remove => {
            const keep = (try invokeCallable(rt, env, caps[1], args[1..], loc)).isTruthy();
            if (keep == (kind == .filter)) return invokeCallable(rt, env, downstream, args, loc);
            return args[0];
        },
        .take => {
            roots.values[2] = volatile_cell.current(caps[1]);
            roots.values[1] = try math.dec(rt, env, &.{volatile_cell.current(caps[1])}, loc);
            volatile_cell.setCurrent(caps[1], roots.values[1]);
            // Clojure decrements before invoking rf, and tests THIS invocation's
            // nm afterwards. A reentrant downstream call may change the volatile.
            const positive = (try math.gt(rt, env, &.{ roots.values[2], Value.initInteger(0) }, loc)).isTruthy();
            roots.values[0] = if (positive) try invokeCallable(rt, env, downstream, args, loc) else args[0];
            if (!(try math.gt(rt, env, &.{ roots.values[1], Value.initInteger(0) }, loc)).isTruthy() and
                !reduced.isReduced(roots.values[0]))
                return reduced.alloc(rt, roots.values[0]);
            return roots.values[0];
        },
    }
}

fn Constructor(comptime kind: Kind) type {
    return struct {
        fn call(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
            _ = env;
            try error_catalog.checkArity("__" ++ @tagName(kind) ++ "-xform", args, 1, loc);
            var roots: Roots = .{};
            roots.push(.nil_val, args);
            defer roots.pop();
            return tree_walk.allocNativeFunction(rt, &.{ Value.initInteger(@intFromEnum(kind)), args[0] }, null, &xformCall);
        }
    };
}

pub fn register(env: *Env, ns: *env_mod.Namespace) !void {
    inline for (.{ Kind.map, Kind.filter, Kind.remove, Kind.take }) |kind| {
        _ = try env.intern(ns, "__" ++ @tagName(kind) ++ "-xform", Value.initBuiltinFn(&Constructor(kind).call), null);
    }
}
