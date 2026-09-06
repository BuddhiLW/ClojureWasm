// SPDX-License-Identifier: EPL-2.0
//! Bounded fixed-worker executor core.
//!
//! This module owns scheduling and lifecycle only.  Java queue/class details
//! arrive through `QueueAdapter`; `ThreadPoolExecutor.zig` is the host-surface
//! adapter.  A submitted callable is retained by an executor-owned pending
//! Future, queued as that Future value, and completed by one of the fixed OS
//! workers (or synchronously by CallerRuns saturation).

const std = @import("std");
const Value = @import("../value/value.zig").Value;
const Runtime = @import("../runtime.zig").Runtime;
const Env = @import("../env.zig").Env;
const SourceLocation = @import("../error/info.zig").SourceLocation;
const error_catalog = @import("../error/catalog.zig");
const future = @import("../future.zig");
const dispatch = @import("../dispatch.zig");
const worker_error = @import("worker_error.zig");
const io_default = @import("io_default.zig");
const eval_budget = @import("eval_budget.zig");
const clock = @import("../clock.zig");
const mark_sweep = @import("../gc/mark_sweep.zig");
const gc_heap_mod = @import("../gc/gc_heap.zig");

pub const QueueAdapter = struct {
    value: Value,
    offer: *const fn (*Runtime, Value, Value) anyerror!bool,
    poll: *const fn (*Runtime, Value) anyerror!?Value,
};

pub const PoolState = struct {
    rt: *Runtime,
    env: *Env,
    queue: QueueAdapter,
    thread_factory: Value,
    rejection_handler: Value,
    pool_value: Value = .nil_val,
    mutex: std.Io.Mutex = .init,
    work_available: std.Io.Condition = .init,
    terminated: std.Io.Condition = .init,
    generation: u64 = 0,
    live_workers: u32 = 0,
    shutting_down: bool = false,
    caller_runs: bool,
};

fn invokeCallable(st: *PoolState, callable: Value) anyerror!Value {
    switch (callable.tag()) {
        .fn_val, .builtin_fn, .protocol_fn, .multi_fn => {
            const vt = st.rt.vtable orelse return error.NoVTable;
            return vt.callFn(st.rt, st.env, callable, &.{}, .{});
        },
        else => {},
    }

    var callable_site: dispatch.CallSite = .{};
    if (try dispatch.dispatchBareOrNull(
        st.rt,
        st.env,
        &callable_site,
        callable,
        "call",
        &.{callable},
        .{},
    )) |result| return result;

    var runnable_site: dispatch.CallSite = .{};
    if (try dispatch.dispatchBareOrNull(
        st.rt,
        st.env,
        &runnable_site,
        callable,
        "run",
        &.{callable},
        .{},
    )) |_| return .nil_val;
    return error.NotCallable;
}

fn runTask(st: *PoolState, future_value: Value, may_touch_heap: bool) void {
    if (future.isCancelled(future_value) or !may_touch_heap) {
        future.discardPending(future_value);
        return;
    }

    const f = future_value.decodePtr(*future.Future);
    const callable = f.thunk;
    const scope = future.enterPending(future_value);
    if (invokeCallable(st, callable)) |result| {
        scope.leave();
        future.complete(future_value, result);
    } else |_| {
        const err_value = worker_error.capture(st.rt);
        scope.leave();
        future.completeError(future_value, err_value);
    }
}

/// Runtime-service entry attached to each ThreadFactory-created Thread.  The
/// Thread layer owns OS spawning and GC registration; this layer owns only the
/// queue loop and pool lifecycle.
pub fn workerEntry(context: *anyopaque, registered: bool) void {
    const st: *PoolState = @ptrCast(@alignCast(context));

    while (true) {
        io_default.lockMutex(&st.mutex);
        const observed_generation = st.generation;
        io_default.unlockMutex(&st.mutex);

        if (registered) {
            if (st.queue.poll(st.rt, st.queue.value)) |maybe_task| {
                if (maybe_task) |task| {
                    runTask(st, task, true);
                    continue;
                }
            } else |_| {
                // A failed poll is an empty observation for this worker loop.
            }
        }

        io_default.lockMutex(&st.mutex);
        if (st.shutting_down) {
            io_default.unlockMutex(&st.mutex);
            break;
        }
        if (st.generation == observed_generation)
            io_default.condWait(&st.work_available, &st.mutex);
        io_default.unlockMutex(&st.mutex);
    }

    var release_pool = false;
    io_default.lockMutex(&st.mutex);
    std.debug.assert(st.live_workers > 0);
    st.live_workers -= 1;
    if (st.live_workers == 0) {
        io_default.condBroadcast(&st.terminated);
        release_pool = true;
    }
    io_default.unlockMutex(&st.mutex);
    if (release_pool) _ = st.rt.gc.unpin(st.pool_value);
}

/// Pin the host value before the surface begins creating workers.  The surface
/// uses real Thread objects (including a caller-supplied ThreadFactory); no
/// submit path creates an OS thread.
pub fn prepareStart(st: *PoolState, pool_value: Value) !void {
    st.pool_value = pool_value;
    try st.rt.gc.pin(pool_value);
}

pub fn workerWillStart(st: *PoolState) void {
    io_default.lockMutex(&st.mutex);
    st.live_workers += 1;
    io_default.unlockMutex(&st.mutex);
}

/// Roll back one reserved worker and stop already-started siblings after any
/// factory/attach/start failure.  Last owner releases the pool pin.
pub fn workerStartFailed(st: *PoolState, reserved: bool) void {
    var release_pool = false;
    io_default.lockMutex(&st.mutex);
    if (reserved) {
        std.debug.assert(st.live_workers > 0);
        st.live_workers -= 1;
    }
    st.shutting_down = true;
    st.generation +%= 1;
    io_default.condBroadcast(&st.work_available);
    if (st.live_workers == 0) release_pool = true;
    io_default.unlockMutex(&st.mutex);
    if (release_pool) _ = st.rt.gc.unpin(st.pool_value);
}

pub fn submit(st: *PoolState, callable: Value, loc: SourceLocation) !Value {
    const result = try future.allocPending(st.rt, st.env, callable);

    // Acceptance and shutdown share one lock.  Without this critical section,
    // shutdown could let every worker exit between the state check and enqueue,
    // stranding a pinned Future forever.
    io_default.lockMutex(&st.mutex);
    if (st.shutting_down) {
        io_default.unlockMutex(&st.mutex);
        future.discardPending(result);
        return error_catalog.raise(.executor_rejected, loc, .{ .reason = "executor is shut down" });
    }
    const offered = st.queue.offer(st.rt, st.queue.value, result) catch |e| {
        io_default.unlockMutex(&st.mutex);
        future.discardPending(result);
        return e;
    };
    if (offered) {
        st.generation +%= 1;
        io_default.condSignal(&st.work_available);
        io_default.unlockMutex(&st.mutex);
        return result;
    }
    io_default.unlockMutex(&st.mutex);

    if (st.caller_runs) {
        runTask(st, result, true);
        return result;
    }
    future.discardPending(result);
    return error_catalog.raise(.executor_rejected, loc, .{ .reason = "work queue is saturated" });
}

pub fn shutdown(st: *PoolState) void {
    io_default.lockMutex(&st.mutex);
    st.shutting_down = true;
    st.generation +%= 1;
    io_default.condBroadcast(&st.work_available);
    io_default.unlockMutex(&st.mutex);
}

pub fn isShutdown(st: *PoolState) bool {
    io_default.lockMutex(&st.mutex);
    defer io_default.unlockMutex(&st.mutex);
    return st.shutting_down;
}

pub fn isTerminated(st: *PoolState) bool {
    io_default.lockMutex(&st.mutex);
    defer io_default.unlockMutex(&st.mutex);
    return st.shutting_down and st.live_workers == 0;
}

pub fn awaitTermination(st: *PoolState, timeout_ns: i64) !bool {
    const deadline = clock.nanoTime(st.rt.io) +| @max(timeout_ns, 0);
    while (!isTerminated(st)) {
        const remaining = deadline - clock.nanoTime(st.rt.io);
        if (remaining <= 0) return false;
        try eval_budget.budgetedSleep(
            st.rt.io,
            @intCast(@min(remaining, @as(i64, std.time.ns_per_ms))),
            future.currentCancelLatch(),
        );
        if (future.cancelRequested())
            return error_catalog.raise(.future_cancel_abort, .{}, .{});
    }
    return true;
}

/// Pool values root the observable work queue and constructor collaborators.
/// Queued Futures root their own callables.
pub fn traceState(gc_ptr: *anyopaque, state_words: *[4]u64) void {
    const st: *PoolState = @ptrFromInt(@as(usize, @intCast(state_words[0])));
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    inline for (.{ st.queue.value, st.thread_factory, st.rejection_handler }) |v| {
        if (v.heapHeader()) |hdr| mark_sweep.mark(gc, hdr);
    }
}

/// Reachable only after the last worker released the pool pin (or before start).
pub fn finaliseState(infra: std.mem.Allocator, state_words: *[4]u64) void {
    const st: *PoolState = @ptrFromInt(@as(usize, @intCast(state_words[0])));
    infra.destroy(st);
}
