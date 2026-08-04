// SPDX-License-Identifier: EPL-2.0
//! EvalBudget — an in-process bound on a single eval's execution (ADR-0125):
//! a step ceiling (deterministic, dual-backend-testable) AND/OR a wall-clock
//! deadline (the real untrusted-code bound). Both axes are optional; an
//! unmetered budget (both null) is the default and costs one branch per poll.
//!
//! Polled at the back-edge safe points of BOTH backends (VM + TreeWalk) so a
//! non-allocating infinite loop is caught either way. On expiry it raises an
//! UNCATCHABLE `resource_exhausted` error (kindToHostClass→null): untrusted
//! code cannot swallow its own timeout via `(try … (catch Throwable …))`.
//! Once tripped it LATCHES — every subsequent poll re-raises — so a
//! straight-line burst after the (uncatchable) raise cannot make progress.
//!
//! F-006: the wall-clock read goes through the injected `io` (Runtime.io),
//! never a global clock.
//!
//! Backend: impl-only
//! Impl deps: none
//! Clojure peer: none (armed via CLJW_EVAL_MAX_STEPS / CLJW_EVAL_DEADLINE_MS;
//!   a `cljw.eval/with-budget` scoped surface is D-355's call)
const std = @import("std");
const error_catalog = @import("../error/catalog.zig");
const clock = @import("../clock.zig");
const io_default = @import("io_default.zig");
const Latch = @import("latch.zig").Latch;
const ClojureWasmError = error_catalog.ClojureWasmError;

pub const EvalBudget = struct {
    /// Max back-edge crossings; null = no step bound.
    step_ceiling: ?u64 = null,
    /// Monotonic-clock deadline in ns (clock.nanoTime); null = no time bound.
    deadline_ns: ?i64 = null,
    /// The configured wall-clock budget in ms, for the error message only.
    deadline_ms: i64 = 0,
    /// Running back-edge counter.
    steps: u64 = 0,
    /// Which axis tripped (latch): once non-`.none`, every tick re-raises it.
    tripped: Axis = .none,

    pub const Axis = enum { none, steps, deadline };

    /// Read the wall clock only every 1024th step — a clock syscall per
    /// back-edge would dominate the hot loop. Power-of-two so the throttle
    /// test is a mask, not a modulo.
    const clock_poll_mask: u64 = 1023;

    /// Charge one back-edge crossing. Raises (uncatchable) on expiry; the
    /// latch makes a re-entered poll re-raise the same axis.
    pub fn tick(self: *EvalBudget, io: std.Io) ClojureWasmError!void {
        switch (self.tripped) {
            .none => {},
            .steps => return self.raiseSteps(),
            .deadline => return self.raiseDeadline(),
        }
        self.steps += 1;
        if (self.step_ceiling) |ceiling| {
            if (self.steps > ceiling) {
                self.tripped = .steps;
                return self.raiseSteps();
            }
        }
        if (self.deadline_ns) |deadline| {
            if (self.steps & clock_poll_mask == 0 and clock.nanoTime(io) > deadline) {
                self.tripped = .deadline;
                return self.raiseDeadline();
            }
        }
    }

    /// Charge WALL CLOCK without charging a step — the entry point a BLOCKING
    /// primitive uses.
    ///
    /// `tick` only runs at a back-edge, and a blocking call makes none: it
    /// consumes time without consuming steps. So `(Thread/sleep 25000)` under a
    /// 3000 ms deadline ran the full 25 s and returned normally — the budget
    /// advertises a wall-clock bound and did not have one. Measured on the
    /// ClojureWasm playground, where one unauthenticated request could park the
    /// server for as long as it asked (D-571).
    ///
    /// Unthrottled, unlike `tick`'s every-1024th-step clock read: a blocking
    /// caller polls on a millisecond-scale slice, so one clock read per slice is
    /// nothing, and throttling it by a step counter that is not advancing would
    /// mean never reading at all.
    pub fn checkDeadline(self: *EvalBudget, io: std.Io) ClojureWasmError!void {
        return self.checkDeadlineAt(clock.nanoTime(io));
    }

    /// `checkDeadline` for a caller that has already read the clock — a
    /// blocking primitive needs `now` anyway, to work out how long it may
    /// sleep, and a second syscall for the same instant is waste.
    pub fn checkDeadlineAt(self: *EvalBudget, now_ns: i64) ClojureWasmError!void {
        switch (self.tripped) {
            .none => {},
            .steps => return self.raiseSteps(),
            .deadline => return self.raiseDeadline(),
        }
        const deadline = self.deadline_ns orelse return;
        if (now_ns > deadline) {
            self.tripped = .deadline;
            return self.raiseDeadline();
        }
    }

    fn raiseSteps(self: *const EvalBudget) ClojureWasmError {
        return error_catalog.raise(.eval_steps_exceeded, .{}, .{ .steps = self.step_ceiling orelse self.steps });
    }
    fn raiseDeadline(self: *const EvalBudget) ClojureWasmError {
        return error_catalog.raise(.eval_deadline_exceeded, .{}, .{ .ms = self.deadline_ms });
    }
};

// --- CLI env arming -------------------------------------------------------
// Parse-once config from `CLJW_EVAL_MAX_STEPS` / `CLJW_EVAL_DEADLINE_MS`, set at
// CLI startup and applied to the process's Runtime at eval start. Module-level
// like `gc_torture.pending_period` / `error_render.logFilePath` (parsed-once CLI
// config, not shared mutable runtime state — the budget COUNTER lives on the
// Runtime per F-006). A future `with-budget` / multi-tenant path sets the slot
// directly, bypassing this env convenience.

var pending_max_steps: ?u64 = null;
var pending_deadline_ms: ?i64 = null;
var pending_heap_bytes: ?usize = null;

/// Record the parsed env budget at CLI startup (called from `cli.zig`).
pub fn configureFromEnv(max_steps: ?u64, deadline_ms: ?i64, heap_bytes: ?usize) void {
    pending_max_steps = max_steps;
    pending_deadline_ms = deadline_ms;
    pending_heap_bytes = heap_bytes;
}

/// The env-armed live-heap ceiling (bytes), or null. The heap cap lives on the
/// GcHeap (where byte accounting is), so `runner` reads this and sets
/// `rt.gc.heap_ceiling` + installs `heapExceededHook`.
pub fn pendingHeapCeiling() ?usize {
    return pending_heap_bytes;
}

/// GcHeap cap-breach hook (vtable, installed on `rt.gc.heap_exceeded_hook`):
/// SETS the uncatchable `eval_heap_exceeded` Info so the refused allocation
/// renders with a proper message + resource_exhausted Kind. `alloc` then returns
/// `error.OutOfMemory` (control flow); the Info drives rendering + uncatchability.
/// Lives here because gc_heap may not import the catalog (big_int cycle).
pub fn heapExceededHook(cap: usize) void {
    // We want raise's side effect (set the threadlocal Info), not its returned
    // error value — `alloc` returns error.OutOfMemory to propagate.
    _ = error_catalog.raise(.eval_heap_exceeded, .{}, .{ .bytes = cap }) catch {};
}

/// If either axis was armed via env, install the budget into `slot`
/// (`&rt.eval_budget`). The deadline is computed relative to NOW so bootstrap
/// time is not charged — call AFTER bootstrap, before the user eval loop.
pub fn installFromEnv(slot: *?EvalBudget, io: std.Io) void {
    if (pending_max_steps == null and pending_deadline_ms == null) return;
    slot.* = .{
        .step_ceiling = pending_max_steps,
        .deadline_ns = if (pending_deadline_ms) |ms| clock.nanoTime(io) + ms * std.time.ns_per_ms else null,
        .deadline_ms = pending_deadline_ms orelse 0,
    };
}

// --- tests ---

const testing = std.testing;

test "unmetered budget never trips" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var b: EvalBudget = .{};
    var i: u32 = 0;
    while (i < 10_000) : (i += 1) try b.tick(th.io());
    try testing.expect(b.tripped == .none);
}

test "step ceiling trips after ceiling+1 ticks, then latches" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var b: EvalBudget = .{ .step_ceiling = 3 };
    try b.tick(th.io()); // steps=1
    try b.tick(th.io()); // steps=2
    try b.tick(th.io()); // steps=3
    try testing.expectError(ClojureWasmError.ResourceExhausted, b.tick(th.io())); // steps=4 > 3
    try testing.expect(b.tripped == .steps);
    // Latched: a re-entered poll re-raises without advancing the program.
    try testing.expectError(ClojureWasmError.ResourceExhausted, b.tick(th.io()));
}

test "a deadline already in the past trips at the first throttle boundary" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    // Deadline 1s in the PAST → the first clock read (step 1024) is already over.
    var b: EvalBudget = .{ .deadline_ns = clock.nanoTime(th.io()) - std.time.ns_per_s, .deadline_ms = 1000 };
    var i: u32 = 0;
    var tripped = false;
    while (i < 2048) : (i += 1) {
        b.tick(th.io()) catch {
            tripped = true;
            break;
        };
    }
    try testing.expect(tripped);
    try testing.expect(b.tripped == .deadline);
}

/// The budget's wall-clock deadline as an absolute `clock.nanoTime` instant, or
/// null when no deadline is armed. This is what a blocking primitive passes to
/// `Latch.wait` so the wait cannot outlast the budget.
pub fn deadlineOf(rt: anytype) ?i64 {
    if (rt.eval_budget) |*b| return b.deadline_ns;
    return null;
}

/// Charge the wall clock without charging a step — the check a blocking
/// primitive makes after it stops blocking, to convert "I waited out the
/// deadline" into the budget error.
pub fn checkDeadlineNow(rt: anytype) ClojureWasmError!void {
    if (rt.eval_budget) |*b| try b.checkDeadlineAt(clock.nanoTime(rt.io));
}

/// Sleep `total_ns`, honouring the eval budget's wall-clock deadline and waking
/// early if `cancel` is raised.
///
/// Both signals are latches on an instant, so neither is polled for. The wait
/// ends at `min(sleep end, budget deadline)`, or the moment `cancel` fires,
/// whichever comes first — one wait, no slices.
///
/// The slicing this replaces cost real time. `future-cancel` needs to notice a
/// cancel promptly, and with only a condition variable available the way to do
/// that was to wake every 20 ms and look. Each wakeup overshoots by a few ms, so
/// a 2000 ms sleep inside a future measured 2321-2358 ms — 17% long, on the most
/// idiomatic metered-blocking expression in Clojure, whether or not any budget
/// was armed. A latch is woken BY the cancel, so there is nothing to look for.
///
/// `rt` rather than a `*EvalBudget`: `with-budget` restores the slot BY VALUE in
/// a `defer`, so a pointer captured before the sleep can outlive the optional's
/// payload.
pub fn budgetedSleep(rt: anytype, total_ns: u64, cancel: ?*Latch) ClojureWasmError!void {
    const now = clock.nanoTime(rt.io);
    if (rt.eval_budget) |*b| try b.checkDeadlineAt(now);

    // `Thread/sleep` accepts any `long`, so `total_ns` can be saturated to
    // maxInt(u64) — clamp before it reaches the i64 instant arithmetic.
    const span: i64 = @intCast(@min(total_ns, @as(u64, std.math.maxInt(i64) / 2)));
    var deadline = now +| span;
    if (deadlineOf(rt)) |d| deadline = @min(deadline, d);

    if (cancel) |latch| {
        // Returns early iff the cancel fired; the caller re-checks and unwinds.
        _ = latch.wait(deadline);
    } else {
        const remaining = deadline - clock.nanoTime(rt.io);
        if (remaining > 0) io_default.sleep(@intCast(remaining));
    }

    // A deadline that landed during the sleep still trips, so the caller unwinds
    // rather than returning as though it had waited out a budget it exceeded.
    try checkDeadlineNow(rt);
}

test "budgetedSleep: a past deadline trips on the first poll" {
    var fake: FakeRt = .{ .eval_budget = .{ .deadline_ns = clock.nanoTime(testing.io) - std.time.ns_per_s, .deadline_ms = 1 } };
    try testing.expectError(error.ResourceExhausted, budgetedSleep(&fake, 5 * std.time.ns_per_s, null));
    // Latched, so a second call re-raises the same axis rather than sleeping.
    try testing.expectEqual(EvalBudget.Axis.deadline, fake.eval_budget.?.tripped);
}

test "budgetedSleep: a metered sleep that does NOT expire keeps its duration" {
    // The regression this shape exists to prevent: slicing the sleep to poll for
    // a cancel made every metered sleep ~20% long. Waiting on an instant means
    // one uninterrupted wait whenever the deadline is beyond the sleep's end.
    const want_ns: u64 = 120 * std.time.ns_per_ms;
    var fake: FakeRt = .{ .eval_budget = .{
        .deadline_ns = clock.nanoTime(testing.io) + 60 * std.time.ns_per_s,
        .deadline_ms = 60_000,
    } };
    const t0 = clock.nanoTime(testing.io);
    try budgetedSleep(&fake, want_ns, null);
    const elapsed: u64 = @intCast(clock.nanoTime(testing.io) - t0);
    try testing.expect(elapsed >= want_ns);

    // NO upper bound is asserted, deliberately.
    //
    // The first version of this test asserted `elapsed < want_ns * 3 / 2` to
    // catch the ~20% inflation that per-slice polling used to cost. It passed
    // locally and failed on the CI macOS runner, because a shared runner's
    // scheduling noise on a 120 ms sleep is larger than the 20% signal. A
    // wall-clock UPPER bound in a unit test is a flake generator: it cannot
    // separate a systematic regression from a busy machine, so it eventually
    // fails for the one reason it was not written to detect.
    //
    // The property is real and is still checked — just not here. It is a
    // measurement, so it lives where measurements can be taken on a quiet
    // machine: the numbers are in ADR-0182's Consequences (2321-2358 ms ->
    // 2000-2001 ms for `@(future (Thread/sleep 2000))`). What a unit test can
    // assert deterministically is the lower bound above: a metered sleep must
    // not return EARLY, which is what a mis-computed slice would do.
}

test "budgetedSleep: no budget and no cancel poll is one uninterrupted sleep" {
    var fake: FakeRt = .{ .eval_budget = null };
    const want_ns: u64 = 40 * std.time.ns_per_ms;
    const t0 = clock.nanoTime(testing.io);
    try budgetedSleep(&fake, want_ns, null);
    const elapsed: u64 = @intCast(clock.nanoTime(testing.io) - t0);
    try testing.expect(elapsed >= want_ns);
}

/// The two fields `budgetedSleep` reads off a Runtime. Kept minimal on purpose:
/// the helper takes `anytype` so it can be exercised without standing up a real
/// Runtime, and re-reading `eval_budget` per iteration (rather than caching a
/// pointer) is the property this stand-in also has.
const FakeRt = struct {
    eval_budget: ?EvalBudget,
    io: std.Io = testing.io,
};
