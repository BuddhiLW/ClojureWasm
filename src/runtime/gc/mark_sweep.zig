// SPDX-License-Identifier: EPL-2.0
//! Mark + sweep phases for cw v1 mark-sweep GC per ADR-0028 §1 + §4 + §5.
//!
//! Two stop-the-world phases plus the `collect()` orchestrator:
//!   - `mark(gc, header)` — shades an object gray: sets
//!     `HeapHeader.gc_and_lock.gc_mark` (bit 0) and pushes non-leaf
//!     headers onto `gc.mark_worklist` (ADR-0028 amendment 3 — the
//!     prior recursive descent overflowed the native stack on deep
//!     cons chains). The bit doubles as the visited flag —
//!     cycle-mark invariant per ADR-0028 §5.
//!   - `drainGray(gc)` — blackens the worklist: pops headers and runs
//!     their per-tag trace fn (`tag_ops.tag_trace_table`) until empty.
//!   - `sweep(gc)` — walks the live list. For every object with
//!     `mark == 0`: call per-tag finaliser via
//!     `tag_ops.tag_finaliser_table` (no-alloc invariant per ADR-0028
//!     §4), push onto the matching free pool (rawFree fallback),
//!     swap-remove from the live list. For every object with
//!     `mark == 1`: clear the bit and keep.
//!   - `collect(gc, ctx)` — enumerates roots via `root_set.enumerate`,
//!     shades each gray, drains the worklist (blacken), sweeps, then
//!     recomputes the adaptive `threshold_bytes` per ADR-0028 §1.
//!
//! `clearMarks(gc)` resets every live object's mark bit (used by tests
//! and reserved for an explicit clear pass). All four are landed.

const std = @import("std");
const clock = @import("../clock.zig");
const max_threshold_floor_bytes = @import("gc_heap.zig").max_threshold_floor_bytes;
const gc_time_target_percent = @import("gc_heap.zig").gc_time_target_percent;
const testing = std.testing;

const gc_heap_mod = @import("gc_heap.zig");
const heap_header = @import("../value/heap_header.zig");
const tag_ops = @import("tag_ops.zig");
const free_pool_mod = @import("free_pool.zig");
const root_set_mod = @import("root_set.zig");
const io_default = @import("../concurrency/io_default.zig");
const safepoint = @import("../concurrency/safepoint.zig");
const lock_tx = @import("../concurrency/lock_tx.zig");

/// Adapter so `lock_tx.markRoots` can call back into `mark` with the GcHeap as
/// an opaque context (avoids a lock_tx → mark_sweep import).
fn markTxHeader(ctx: *anyopaque, header: *HeapHeader) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(ctx));
    mark(gc, header);
}

/// Adapter for `root_set.markRegisteredTxs`: cast the opaque `current_tx` value
/// back to a transaction and mark its in-txn roots. Called once per registered
/// worker thread during a collect (#4a' in-txn-map rooting).
fn markWorkerTx(ctx: *anyopaque, tx_opaque: ?*anyopaque) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(ctx));
    const tx_any = tx_opaque orelse return;
    const tx: *lock_tx.LockingTransaction = @ptrCast(@alignCast(tx_any));
    lock_tx.markRoots(tx, @ptrCast(gc), &markTxHeader);
}

const GcHeap = gc_heap_mod.GcHeap;
const HeapHeader = heap_header.HeapHeader;

// CLJW_GC_STATS=3 — cumulative per-phase collect time, printed per collect.
// The diagnostic that attributed D-450's ~24ms-per-collect fixed cost to the
// prep phase (clearPersistentMarks over 15.5M immortal closures); kept, like
// the =2 owned-bytes breakdown, because the next attribution will want it.
// Accumulation is unconditional: ~5 clock reads per collect, noise next to a
// single collect's work.
var phase_prep_ns: u64 = 0;
var phase_roots_ns: u64 = 0;
var phase_scan_ns: u64 = 0;
var phase_drain_ns: u64 = 0;
var phase_sweep_ns: u64 = 0;

/// Shade a heap object gray: set `header.gc_and_lock.gc_mark` bit 0 and
/// push the header onto `gc.mark_worklist` for `drainGray` to blacken.
/// Recursive per-child descent was retired by ADR-0028 amendment 3 — a
/// deep object graph (a ≥400k-long cons chain from
/// `(count (repeat 1000000 1))`) overflowed the native stack during a
/// mid-walk collect; the explicit worklist keeps mark depth O(1).
///
/// Cycle invariant (per ADR-0028 §5 Mark cycle invariant): if the
/// header's mark bit is already set, return immediately — the bit
/// doubles as a visited flag during the mark phase. Cycles
/// (e.g. `LazySeq` whose `thunk` captures another `LazySeq` whose
/// `seq_cache` points back) terminate at the second visit.
///
/// LOAD-BEARING ordering: the bit is set BEFORE the push. Push-before-bit
/// would let a failed push leave a marked-looking-but-untraced object,
/// so a live child could be swept (UAF). Bit-before-push also bounds the
/// worklist: each object enters at most once, so `collect()` can reserve
/// `allocations + persistent_marks` capacity up front and the in-collect
/// append never allocates.
///
/// Per-tag trace dispatch: `tag_ops.tag_trace_table[hdr.tag]` returns
/// the type-specific outgoing-pointer walker, registered per-tag via
/// `tag_ops.registerTrace`. A `null` entry means a genuine leaf node
/// (e.g. `string`, `big_int` limb data) — mark sets the bit and never
/// pushes it.
pub fn mark(gc: *GcHeap, header: *HeapHeader) void {
    if (header.gc_and_lock.gc_mark & 1 == 1) return; // cycle invariant
    header.gc_and_lock.gc_mark |= 1;
    if (tag_ops.tag_trace_table[header.tag] == null) return; // leaf
    // In-collect this never allocates (capacity reserved up front); a
    // direct `mark` caller outside collect (unit tests) may grow the
    // worklist on `gc.infra`. True infra OOM here is unrecoverable —
    // continuing would strand unmarked live children and sweep them.
    gc.mark_worklist.append(gc.infra, header) catch
        @panic("GC mark: gray worklist allocation failed");
}

/// Blacken the gray worklist: pop headers and run their per-tag trace
/// fn (which shades children gray via `mark`) until the worklist is
/// empty. The explicit drain is a named phase of `collect()` — publish
/// roots (gray) → drainGray (blacken) → sweep — the textbook tri-color
/// structure a future incremental / parallel marker inherits. Direct
/// `mark()` callers outside collect (unit tests) must call this to get
/// transitive marking.
pub fn drainGray(gc: *GcHeap) void {
    while (gc.mark_worklist.pop()) |header| {
        // Only non-leaf headers are ever pushed, so the table entry is set.
        tag_ops.tag_trace_table[header.tag].?(@ptrCast(gc), header);
    }
}

/// Reset the mark bit on every live allocation. `collect()` already
/// clears marks on surviving objects inline during `sweep`, so this
/// stands alone for tests and an explicit clear-pass caller.
pub fn clearMarks(gc: *GcHeap) void {
    for (gc.allocations.items) |rec| {
        rec.header.gc_and_lock.gc_mark &= ~@as(u30, 1);
    }
}

/// Walk the live list, finalise + recycle unreached objects, clear
/// marks on reached ones. Iterates `gc.allocations` backward (so
/// swap-remove indices stay valid). For each record:
///   - mark bit 0 == 0 (dead): call per-tag finaliser via
///     `tag_ops.tag_finaliser_table` (no-alloc invariant per
///     ADR-0028 §4), push the backing memory onto the matching free
///     pool (`FreePoolMap.push`; rawFree fallback on push failure),
///     swap-remove from allocations, bump `bytes_freed` + `sweep_count`.
///   - mark bit 0 == 1 (live): clear the bit, sum into
///     `last_live_bytes` for the next adaptive-threshold cycle.
pub fn sweep(gc: *GcHeap) void {
    // CLJW_GC_STATS=2 — per-tag owned-bytes breakdown of the LIVE set, printed
    // per sweep. The diagnostic that found the D-573 numbers; kept because the
    // next accounting question will want it too.
    const debug_owned = if (@import("../process_env.zig").get("CLJW_GC_STATS")) |v| std.mem.eql(u8, v, "2") else false;
    var owned_by_tag: [64]usize = @splat(0);
    var count_by_tag: [64]usize = @splat(0);
    var live_bytes: usize = 0;
    var i: usize = gc.allocations.items.len;
    while (i > 0) {
        i -= 1;
        const rec = gc.allocations.items[i];
        const mark_bit: u30 = rec.header.gc_and_lock.gc_mark & 1;
        if (mark_bit == 0) {
            if (tag_ops.tag_finaliser_table[rec.header.tag]) |finaliser| {
                finaliser(@ptrCast(gc), rec.header);
            }
            const mem: [*]u8 = @ptrCast(rec.header);
            const key = free_pool_mod.FreePoolKey{ .size = rec.size, .alignment = rec.alignment };
            // Push onto the matching free pool for reuse; fall through
            // to direct rawFree only if push fails (e.g. infra OOM
            // during HashMap getOrPut for a never-before-seen key).
            gc.free_pools.push(key, mem) catch {
                gc.infra.rawFree(mem[0..rec.size], rec.alignment, @returnAddress());
            };
            gc.stats.bytes_freed += rec.size;
            _ = gc.allocations.swapRemove(i);
        } else {
            rec.header.gc_and_lock.gc_mark &= ~@as(u30, 1);
            live_bytes += rec.size;
            // D-573: count what the object OWNS, not just its record block —
            // a String's bytes, a BigInt's limbs, an array's elements. The
            // trigger steers on this number; an invisible payload made the
            // adaptive arm read as inert on exactly the heaviest heaps.
            if (tag_ops.tag_owned_bytes_table[rec.header.tag]) |owned| {
                const n = owned(rec.header);
                live_bytes += n;
                if (debug_owned) {
                    owned_by_tag[rec.header.tag] += n;
                    count_by_tag[rec.header.tag] += 1;
                }
            }
        }
    }
    if (debug_owned) {
        for (owned_by_tag, 0..) |n, tag| {
            if (n > 0) std.debug.print("[gc-owned] tag={d} count={d} bytes={d}\n", .{ tag, count_by_tag[tag], n });
        }
        std.debug.print("[gc-owned] persistent_bytes={d}\n", .{gc.persistent_bytes});
    }
    gc.stats.sweep_count += 1;
    // Deliberately EXCLUDES `gc.persistent_bytes`. The trigger has two arms
    // with separate jobs: this byte arm sizes the threshold against the SWEPT
    // heap (allocate ~2x what is live before collecting again), and the
    // time-share arm (ADR-0183 steerFloor) absorbs the cost of everything a
    // collection actually traces — including the process-lifetime waypoints,
    // which grow with every closure created and are re-traced every cycle.
    // Folding them in here was measured to regress gc_alloc_rate ~11%: it
    // inflates the threshold from bootstrap onward, collections stop
    // refilling the free pool, and the alloc path degrades to malloc
    // (ADR-0164's finding). The waypoints' cost is real, and the arm that
    // measures real cost is the one that owns it.
    gc.stats.last_live_bytes = live_bytes;
}

/// Full mark-sweep collection cycle: enumerate every root via
/// `root_set.enumerate(ctx)`, mark each transitively (per-tag trace
/// dispatch handles outgoing pointers), sweep the live list
/// (per-tag finaliser → push onto free pool / direct rawFree
/// fallback), then update the adaptive threshold per ADR-0028 §1
/// (`threshold_bytes = max(default, last_live_bytes * 2)`) and
/// reset `bytes_since_last_gc`.
///
/// Callers invoke this directly rather than through a method on
/// `GcHeap` because the cycle traverses `root_set.zig` which itself
/// imports `gc_heap.zig` — the entry point lives here in
/// `mark_sweep.zig` to keep the import graph acyclic.
///
/// Adaptive-threshold semantics (per ADR-0028 §1 Load-bearing
/// concern #2 disposition): after sweep updates `stats.last_live_bytes`,
/// the next-trigger threshold is recomputed so it doubles on each
/// growth cycle. Prevents the "first def triggers a full GC mid-
/// load on a 4 MiB Clojure source" failure mode.
pub fn collect(gc: *GcHeap, ctx: root_set_mod.WalkContext) void {
    // Whole collection runs under the global heap lock (ADR-0090 §2): no
    // mutator can allocate while mark+sweep run. Not reentrant — mark/sweep
    // never allocate THROUGH `gc.alloc` (so no torture re-entry and no
    // `gc_mutex` re-take); the gray worklist's capacity is reserved here on
    // `gc.infra`, before any mark bit is set, so the mark phase itself
    // performs no allocation at all.
    const t_entry = clock.nanoTime(io_default.get());
    io_default.lockMutex(&gc.gc_mutex);
    defer io_default.unlockMutex(&gc.gc_mutex);
    // Bit-set-at-push ⇒ each object enters the gray worklist at most once,
    // so `allocations + persistent_marks` bounds it (infra-lifetime
    // singletons like the interned empty list add a handful; the fallible
    // append in `mark` absorbs them). A failed reserve aborts this collect
    // BEFORE any bit is set — a safe degradation (heap intact; the pressure
    // resurfaces as OOM at the next `gc.alloc`), unlike a mid-mark OOM.
    gc.mark_worklist.ensureTotalCapacity(
        gc.infra,
        gc.allocations.items.len + gc.persistent_marks.items.len,
    ) catch return;
    // D-251: clear the mark bit on process-lifetime trackHeap'd waypoints
    // (Functions etc.) so each is re-traced this cycle. They are never swept
    // (not in `allocations`), so sweep never clears their bit; an un-cleared
    // bit short-circuits `mark()` and strands their GC children (a closure's
    // `closure_bindings`) from the 2nd collect onward.
    gc.clearPersistentMarks();
    const t_prep = clock.nanoTime(io_default.get());
    phase_prep_ns +|= @intCast(@max(0, t_prep - t_entry));
    var it = root_set_mod.enumerate(ctx);
    while (it.next()) |root_header| {
        mark(gc, root_header);
    }
    // #4a' in-txn-map rooting: the collecting thread's `dosync` body may hold
    // live Values in `current_tx`'s gpa `vals`/`commutes` maps that are on no
    // operand stack — mark them so a mid-transaction collect does not sweep
    // them. (Parked WORKER threads' transactions are a follow-up — the registry
    // tx-slot exposure; today's collects are quiescent/single-tx.)
    if (lock_tx.current_tx) |tx| lock_tx.markRoots(tx, @ptrCast(gc), &markTxHeader);
    // ...and every registered WORKER thread's transaction (parked at a safepoint
    // during STW, so its tx is quiescent). Empty registry in single-thread → no-op.
    root_set_mod.markRegisteredTxs(@ptrCast(gc), &markWorkerTx);
    // D-556: conservative native-stack scan (tree_walk backend only — the vm's
    // operand stack is the A1 root). Pins every stack word that decodes to a
    // live heap Value, covering evaluation intermediates the explicit brackets
    // miss. Runs on the COLLECTING thread's stack only. Parked workers are safe
    // WITHOUT a scan because a park can no longer fire inside a fabrication
    // bracket (D-559 / ADR-0150 am1 — the alloc-prologue park honors
    // `fabrication_depth`), so a parked worker's builder intermediates are never
    // exposed; its Values are published (eval frames / bindings / operand
    // stack). Residual: tree_walk eval RUNNING ON A WORKER holds C-stack Value
    // intermediates this main-only scan does not cover (the D-556 residual).
    const t_scan0 = clock.nanoTime(io_default.get());
    phase_roots_ns +|= @intCast(@max(0, t_scan0 - t_prep));
    conservativeStackScan(gc);
    const t_scan1 = clock.nanoTime(io_default.get());
    // All roots are shaded gray; blacken transitively (ADR-0028 amendment 3).
    drainGray(gc);
    const t_drain = clock.nanoTime(io_default.get());
    sweep(gc);
    const t_sweep = clock.nanoTime(io_default.get());
    phase_scan_ns +|= @intCast(@max(0, t_scan1 - t_scan0));
    phase_drain_ns +|= @intCast(@max(0, t_drain - t_scan1));
    phase_sweep_ns +|= @intCast(@max(0, t_sweep - t_drain));
    if (@import("../process_env.zig").get("CLJW_GC_STATS")) |v| {
        if (std.mem.eql(u8, v, "3"))
            std.debug.print("[gc-phases] prep_ms={d} roots_ms={d} scan_ms={d} drain_ms={d} sweep_ms={d} (cum)\n", .{ phase_prep_ns / 1_000_000, phase_roots_ns / 1_000_000, phase_scan_ns / 1_000_000, phase_drain_ns / 1_000_000, phase_sweep_ns / 1_000_000 });
    }
    // D-573: ramp the FLOOR when a collection turns out to have been mostly
    // garbage.
    //
    // ADR-0164 set a fixed 4 MB floor and noted, correctly, that for a churn
    // workload `last_live ~ 0` makes the adaptive `last_live*2` arm inert — so
    // the constant becomes the operative number. It was tuned against short
    // benchmark scripts. On a long allocation-heavy program a constant is the
    // wrong shape, because the cost of a collection is mostly FIXED (root scan
    // + sweep of the side table), not proportional to what it reclaims.
    //
    // Measured on a Rush Hour BFS (cw-arcade), same 3.17 GB allocated over
    // 26.2M allocations either way:
    //
    //     floor    collections   wall
    //     4 MB         755       17.7 s
    //     64 MB         47        7.6 s
    //
    // 708 collections avoided, 10.1 s saved — about 13 ms of fixed cost each,
    // paid to reclaim a heap that was nearly all garbage.
    //
    // The condition is exactly the situation ADR-0164 named: the adaptive arm is
    // INERT (`last_live*2` does not reach the floor), so the constant is what
    // governs — and we collected anyway. That is the case where collecting more
    // often buys nothing, so double the floor, capped. Once the live set grows
    // enough for `last_live*2` to exceed the floor, the adaptive arm takes over
    // and the floor stops mattering, which is why the ramp does not need to
    // come back down.
    //
    // A short script is unaffected: the ramp needs collections to happen, and
    // one that never crosses 4 MB never collects. `string_ops` — ADR-0164's
    // named canary, continuous string allocation — ramps, so it collects LESS
    // than before, not more.
    // The floor is the per-heap `threshold_floor_bytes` (default = the module
    // const, overridable by CLJW_GC_THRESHOLD_MB) so the knob survives this
    // recompute; the adaptive `last_live*2` arm is unchanged (growth workloads).
    gc.threshold_bytes = @max(
        gc.threshold_floor_bytes,
        gc.stats.last_live_bytes *| 2,
    );
    gc.bytes_since_last_gc = 0;
    gc.stats.collect_count += 1;
}

/// D-556: conservatively scan the collecting thread's native stack for live
/// heap Values (tree_walk backend). Range: from the collector's own frame
/// (deep) up to `root_set.conservative_stack_top` (the shallowest tree_walk
/// eval entry; 0 = tree_walk never ran on this thread → skip). Each 8-byte
/// word is decoded via the `Value.heapHeader()` membrane (tag check only, no
/// deref) and pinned IFF the pointer matches a live allocation record — a
/// stale/garbage word that happens to look like a heap tag can only pin a
/// still-live object (false positive = one delayed free), never deref a
/// dangling pointer. The live-pointer set is built in one pass over the
/// `allocations` side-table using `gc.infra` (never `gc.alloc` — collect must
/// not re-enter the heap).
/// libc setjmp — used ONLY as a register spill (Boehm GC's `GC_push_regs`
/// idiom): it writes every callee-saved register into the buffer, so a heap
/// Value living ONLY in a callee-saved register (never spilled on the paths
/// the collector happened to take) becomes scannable. We never longjmp.
extern fn setjmp(env: *anyopaque) c_int;

/// Decode one candidate word and pin it if it is a live heap Value.
inline fn pinIfLiveWord(gc: *GcHeap, live: *const std.AutoHashMapUnmanaged(usize, void), word: u64) void {
    const Value = @import("../value/value.zig").Value;
    const nb = @import("../value/nan_box.zig");
    // Pre-filter a zero address: `heapHeader`'s decodePtr would cast it to a
    // null pointer (a ReleaseSafe panic) — a heap-TAGGED word with address
    // bits 0 is garbage, never a real Value.
    if (word & nb.NB_ADDR_SHIFTED_MASK == 0) return;
    const v: Value = @enumFromInt(word);
    const hdr = v.heapHeader() orelse return;
    if (live.contains(@intFromPtr(hdr))) mark(gc, hdr);
}

fn conservativeStackScan(gc: *GcHeap) void {
    const top = root_set_mod.conservative_stack_top;
    if (top == 0) return;
    const bottom = @frameAddress();
    if (bottom >= top) return;
    var live: std.AutoHashMapUnmanaged(usize, void) = .empty;
    defer live.deinit(gc.infra);
    live.ensureTotalCapacity(gc.infra, @intCast(gc.allocations.items.len)) catch return;
    for (gc.allocations.items) |rec| live.putAssumeCapacity(@intFromPtr(rec.header), {});
    // Registers first (see `setjmp` above): 128 u64s comfortably hold any
    // ABI's jmp_buf; unwritten tail words stay zero and are filtered.
    var jb: [128]u64 align(16) = [_]u64{0} ** 128;
    _ = setjmp(@ptrCast(&jb));
    for (jb) |word| pinIfLiveWord(gc, &live, word);
    // Then the native stack from the collector's frame up to the anchor.
    var addr = std.mem.alignForward(usize, bottom, @alignOf(u64));
    while (addr + @sizeOf(u64) <= top) : (addr += @sizeOf(u64)) {
        pinIfLiveWord(gc, &live, @as(*const u64, @ptrFromInt(addr)).*);
    }
}

/// Stop-the-world collect (ADR-0090 Alt B / D-244 #4): pause every other
/// registered worker at a safe point (its `alloc`-prologue park or the VM
/// back-edge poll), run a full `collect` over the union root set (every parked
/// worker's published roots are quiescent), then resume the workers. This is
/// the entry point a real-threading collector calls instead of bare `collect`.
///
/// The caller MUST NOT hold `gc_mutex`: `collect` re-takes it (`Io.Mutex` is
/// not reentrant), so a holder would self-deadlock. At the VM safe point that
/// triggers a collection, `gc_mutex` is free — `alloc` releases it before the
/// trigger runs (#4 wire-up). `self_registered` excludes the calling thread
/// from the park target (true when the collector is itself a registered worker
/// that crossed the threshold, false for the main / unregistered collector).
///
/// With no other registered workers (single-threaded, or every peer already at
/// a safe point) `stopWorld` returns immediately and this is just `collect`
/// with a no-op fence — so it is correct (if heavier) even single-threaded.
pub fn collectStopTheWorld(gc: *GcHeap, ctx: root_set_mod.WalkContext, self_registered: bool) void {
    // D-573: time the collection so the floor can be steered by the MEASURED
    // GC share rather than by a byte constant. The process-wide io clock —
    // every collect site can reach it without an io parameter, and `.awake` is
    // monotonic, which is what a duration needs.
    const started = clock.nanoTime(io_default.get());
    safepoint.stopWorld(self_registered);
    collect(gc, ctx);
    safepoint.resumeWorld();
    const ended = clock.nanoTime(io_default.get());
    gc.stats.gc_ns_total +|= @intCast(@max(0, ended - started));
    if (gc.stats.first_collect_ns == 0) gc.stats.first_collect_ns = started;
    steerFloor(gc, ended);
}

/// Move `threshold_floor_bytes` toward whatever keeps the measured GC share at
/// `gc_time_target_percent`.
///
/// The share is `gc_ns_total / (now - first_collect_ns)` — wall clock since the
/// program first had to collect, which is the window the floor can influence.
/// Over target, the collector is running too often for what it costs to mark
/// this program's live set: double the floor, so twice as much garbage
/// accumulates per collection and the share roughly halves. Under target with
/// room to spare, ease back down, so a program whose live set shrank stops
/// holding a floor it no longer needs.
///
/// Doubling/halving rather than solving for a target: the share is a lagging
/// average, so a single-step solve would oscillate. It converges in a handful
/// of collections either way, which is fast against the hundreds a program has
/// to make before the floor matters at all.
fn steerFloor(gc: *GcHeap, now_ns: i64) void {
    const elapsed = now_ns - gc.stats.first_collect_ns;
    // Below this there is no meaningful ratio yet — a first collection is 100 %
    // of the time since the first collection, which says nothing.
    if (elapsed < 50 * std.time.ns_per_ms) return;
    const share_pct = gc.stats.gc_ns_total * 100 / @as(u64, @intCast(elapsed));
    if (share_pct > gc_time_target_percent) {
        if (gc.threshold_floor_bytes < max_threshold_floor_bytes) {
            gc.threshold_floor_bytes = @min(
                max_threshold_floor_bytes,
                gc.threshold_floor_bytes *| 2,
            );
        }
    } else if (share_pct * 4 < gc_time_target_percent and
        gc.threshold_floor_bytes > gc.base_threshold_floor_bytes)
    {
        gc.threshold_floor_bytes = @max(
            gc.base_threshold_floor_bytes,
            gc.threshold_floor_bytes / 2,
        );
    }
}

// --- tests ---

const Cell = extern struct { header: HeapHeader, payload: u64 = 0 };

test "mark sets gc_mark bit 0 on a leaf header" {
    var gc = GcHeap.init(testing.allocator);
    defer gc.deinit();

    const c = try gc.alloc(Cell);
    c.* = .{ .header = HeapHeader.init(.symbol) };
    try testing.expectEqual(@as(u30, 0), c.header.gc_and_lock.gc_mark);

    mark(&gc, &c.header);
    try testing.expectEqual(@as(u30, 1), c.header.gc_and_lock.gc_mark & 1);
}

test "mark cycle invariant: double-mark is idempotent" {
    var gc = GcHeap.init(testing.allocator);
    defer gc.deinit();

    const c = try gc.alloc(Cell);
    c.* = .{ .header = HeapHeader.init(.list) };

    mark(&gc, &c.header);
    const after_first = c.header.gc_and_lock.gc_mark;
    mark(&gc, &c.header);
    const after_second = c.header.gc_and_lock.gc_mark;
    try testing.expectEqual(after_first, after_second);
}

test "clearMarks resets bit 0 on every live allocation" {
    var gc = GcHeap.init(testing.allocator);
    defer gc.deinit();

    const a = try gc.alloc(Cell);
    a.* = .{ .header = HeapHeader.init(.symbol) };
    const b = try gc.alloc(Cell);
    b.* = .{ .header = HeapHeader.init(.vector) };

    mark(&gc, &a.header);
    mark(&gc, &b.header);
    try testing.expect(a.header.gc_and_lock.gc_mark & 1 == 1);
    try testing.expect(b.header.gc_and_lock.gc_mark & 1 == 1);

    clearMarks(&gc);
    try testing.expectEqual(@as(u30, 0), a.header.gc_and_lock.gc_mark & 1);
    try testing.expectEqual(@as(u30, 0), b.header.gc_and_lock.gc_mark & 1);
}

test "clearMarks preserves bits 1..29 (only bit 0 is the mark)" {
    // Bits 1..29 are reserved per ADR-0028 §6 for tri-colour upgrade +
    // size_class (5.3 owner picks split). clearMarks must not touch
    // them; 5.3.b.2 only resets bit 0.
    var gc = GcHeap.init(testing.allocator);
    defer gc.deinit();

    const c = try gc.alloc(Cell);
    c.* = .{ .header = HeapHeader.init(.symbol) };
    c.header.gc_and_lock.gc_mark = 0b101010101; // arbitrary non-bit-0 pattern + bit 0

    clearMarks(&gc);
    try testing.expectEqual(@as(u30, 0b101010100), c.header.gc_and_lock.gc_mark);
}

test "sweep removes unmarked allocations + frees their backing memory" {
    var gc = GcHeap.init(testing.allocator);
    defer gc.deinit();

    const a = try gc.alloc(Cell);
    a.* = .{ .header = HeapHeader.init(.symbol) };
    const b = try gc.alloc(Cell);
    b.* = .{ .header = HeapHeader.init(.vector) };
    const c = try gc.alloc(Cell);
    c.* = .{ .header = HeapHeader.init(.list) };

    // Mark only `a` and `c` as reachable; `b` is dead.
    mark(&gc, &a.header);
    mark(&gc, &c.header);

    sweep(&gc);

    try testing.expectEqual(@as(usize, 2), gc.allocations.items.len);
    try testing.expectEqual(@as(u64, 1), gc.stats.sweep_count);
    try testing.expectEqual(@as(usize, @sizeOf(Cell)), gc.stats.bytes_freed);
    try testing.expectEqual(@as(usize, 2 * @sizeOf(Cell)), gc.stats.last_live_bytes);

    // Survivors retain their tag and have mark bit reset to 0 (ready
    // for the next mark phase per the sweep contract).
    for (gc.allocations.items) |rec| {
        try testing.expectEqual(@as(u30, 0), rec.header.gc_and_lock.gc_mark & 1);
    }
}

test "sweep on empty heap is a no-op (bumps sweep_count, no panics)" {
    var gc = GcHeap.init(testing.allocator);
    defer gc.deinit();

    sweep(&gc);
    try testing.expectEqual(@as(u64, 1), gc.stats.sweep_count);
    try testing.expectEqual(@as(usize, 0), gc.stats.last_live_bytes);
}

test "collect: pinned roots survive; unpinned allocations get swept" {
    var gc = GcHeap.init(testing.allocator);
    defer gc.deinit();

    const cell_kept = try gc.alloc(Cell);
    cell_kept.* = .{ .header = HeapHeader.init(.symbol) };
    const cell_dropped = try gc.alloc(Cell);
    cell_dropped.* = .{ .header = HeapHeader.init(.vector) };

    const value_mod_test = @import("../value/value.zig");
    try gc.pin(value_mod_test.Value.encodeHeapPtr(.string, cell_kept));

    const before_alloc_count = gc.allocations.items.len;
    try testing.expectEqual(@as(usize, 2), before_alloc_count);

    collect(&gc, .{ .envs = &.{}, .gc = &gc });
    try testing.expectEqual(@as(usize, 1), gc.allocations.items.len);
    try testing.expectEqual(@as(u64, 1), gc.stats.collect_count);
    try testing.expectEqual(@as(usize, @sizeOf(Cell)), gc.stats.last_live_bytes);
    try testing.expectEqual(@as(usize, 0), gc.bytes_since_last_gc);
    try testing.expectEqual(@as(*HeapHeader, @ptrCast(cell_kept)), gc.allocations.items[0].header);
}

test "collect: in-transaction vals values survive (#4a' self-tx rooting)" {
    var gc = GcHeap.init(testing.allocator);
    defer gc.deinit();
    const value_mod_test = @import("../value/value.zig");
    const lock_tx_mod = @import("../concurrency/lock_tx.zig");
    const Ref = @import("../stm/ref.zig").Ref;

    // A heap value that lives ONLY in the transaction's vals cache — on no
    // operand stack, not pinned. Without the #4a' tx-rooting it would be swept.
    const in_tx_cell = try gc.alloc(Cell);
    in_tx_cell.* = .{ .header = HeapHeader.init(.vector) };
    const in_tx_val = value_mod_test.Value.encodeHeapPtr(.vector, in_tx_cell);

    var tx: lock_tx_mod.LockingTransaction = .{ .read_point = 0, .gpa = testing.allocator };
    defer tx.vals.deinit(testing.allocator);
    // A fake (never-dereferenced) Ref key — markRoots reads only the VALUES.
    const fake_ref: *Ref = @ptrFromInt(@alignOf(Ref) * 4096);
    try tx.vals.put(testing.allocator, fake_ref, in_tx_val);

    lock_tx_mod.current_tx = &tx;
    defer lock_tx_mod.current_tx = null;

    collect(&gc, .{ .envs = &.{}, .gc = &gc });

    var found = false;
    for (gc.allocations.items) |a| {
        if (a.header == @as(*HeapHeader, @ptrCast(in_tx_cell))) found = true;
    }
    try testing.expect(found); // survived ONLY via the in-transaction rooting
}

test "collect: a registered worker's transaction roots survive (#4a' worker-tx)" {
    var gc = GcHeap.init(testing.allocator);
    defer gc.deinit();
    const value_mod_test = @import("../value/value.zig");
    const lock_tx_mod = @import("../concurrency/lock_tx.zig");
    const root_set_test = @import("root_set.zig");
    const env_mod_test = @import("../env.zig");
    const Ref = @import("../stm/ref.zig").Ref;

    const in_tx_cell = try gc.alloc(Cell);
    in_tx_cell.* = .{ .header = HeapHeader.init(.vector) };
    const in_tx_val = value_mod_test.Value.encodeHeapPtr(.vector, in_tx_cell);

    var worker_tx: lock_tx_mod.LockingTransaction = .{ .read_point = 0, .gpa = testing.allocator };
    defer worker_tx.vals.deinit(testing.allocator);
    const fake_ref: *Ref = @ptrFromInt(@alignOf(Ref) * 4096);
    try worker_tx.vals.put(testing.allocator, fake_ref, in_tx_val);

    // A registered worker whose current_tx is worker_tx (the MAIN thread's
    // current_tx stays null, so only the worker-tx pass can root in_tx_cell).
    var worker_current_tx: ?*lock_tx_mod.LockingTransaction = &worker_tx;
    var ctx: root_set_test.ThreadGcContext = .{
        .frame_slot = &env_mod_test.current_frame,
        .analysis_frame_slot = &root_set_test.analysis_frame_head,
        .eval_frame_slot = &root_set_test.eval_frame_head,
        .self_guard_slot = &root_set_test.gc_self_guard,
        .tx_slot = @ptrCast(&worker_current_tx),
    };
    try root_set_test.registerThread(&ctx);
    defer root_set_test.unregisterThread(&ctx);

    collect(&gc, .{ .envs = &.{}, .gc = &gc });

    var found = false;
    for (gc.allocations.items) |a| {
        if (a.header == @as(*HeapHeader, @ptrCast(in_tx_cell))) found = true;
    }
    try testing.expect(found); // survived via the registered worker's tx rooting
}

test "collect: adaptive threshold = max(default, last_live_bytes * 2)" {
    var gc = GcHeap.init(testing.allocator);
    defer gc.deinit();

    // No live allocations → last_live_bytes = 0 → threshold stays at default.
    collect(&gc, .{ .envs = &.{}, .gc = &gc });
    try testing.expectEqual(gc_heap_mod.default_gc_threshold_bytes, gc.threshold_bytes);

    // Pin a heap Value so it survives the cycle. last_live_bytes = sizeOf(Cell);
    // since 2 * sizeOf(Cell) is far below default, threshold still stays at default.
    const cell = try gc.alloc(Cell);
    cell.* = .{ .header = HeapHeader.init(.list) };
    const value_mod_test = @import("../value/value.zig");
    try gc.pin(value_mod_test.Value.encodeHeapPtr(.list, cell));

    collect(&gc, .{ .envs = &.{}, .gc = &gc });
    try testing.expectEqual(@as(usize, @sizeOf(Cell)), gc.stats.last_live_bytes);
    try testing.expectEqual(gc_heap_mod.default_gc_threshold_bytes, gc.threshold_bytes);
}

test "sweep iterating backward keeps swap-remove indices valid" {
    // Allocate 5 cells; mark only the middle one (index 2). Sweep
    // should leave exactly that one allocation in place.
    var gc = GcHeap.init(testing.allocator);
    defer gc.deinit();

    var survivor_addr: *HeapHeader = undefined;
    for (0..5) |idx| {
        const cell = try gc.alloc(Cell);
        cell.* = .{ .header = HeapHeader.init(.symbol) };
        if (idx == 2) {
            mark(&gc, &cell.header);
            survivor_addr = &cell.header;
        }
    }

    sweep(&gc);
    try testing.expectEqual(@as(usize, 1), gc.allocations.items.len);
    try testing.expectEqual(survivor_addr, gc.allocations.items[0].header);
}

test "mark bounds native stack on a deep cons chain (explicit worklist)" {
    // A ~1M-deep cons chain: per-child recursive descent would need ~1M
    // native frames and SIGSEGVs (the `(count (repeat 1000000 1))` crash);
    // the explicit worklist keeps mark's stack depth O(1).
    var gc = GcHeap.init(testing.allocator);
    defer gc.deinit();
    const list_mod = @import("../collection/list.zig");
    const value_mod = @import("../value/value.zig");
    const Value = value_mod.Value;
    list_mod.registerGcHooks();

    var tail: Value = .nil_val;
    var i: u32 = 0;
    while (i < 1_000_000) : (i += 1) {
        const cell = try gc.alloc(list_mod.Cons);
        cell.* = .{
            .header = HeapHeader.init(.list),
            .first = .nil_val,
            .rest = tail,
            .meta = .nil_val,
            .count = i + 1,
        };
        tail = Value.encodeHeapPtr(.list, cell);
    }

    mark(&gc, tail.heapHeader().?);
    drainGray(&gc);
    // The deep end (first-allocated cell) must have been reached.
    try testing.expectEqual(@as(u30, 1), gc.allocations.items[0].header.gc_and_lock.gc_mark & 1);
}

test "sweep counts finaliser-owned bytes via the per-tag hook (D-573)" {
    // Register the real string hook, as Runtime.init does.
    const string_mod = @import("../collection/string.zig");
    string_mod.registerGcHooks();

    var gc = GcHeap.init(testing.allocator);
    defer gc.deinit();

    const payload_len = 1000;
    const payload = try gc.infra.alloc(u8, payload_len);
    const s = try gc.alloc(string_mod.String);
    s.* = .{
        .header = HeapHeader.init(.string),
        .bytes_ptr = payload.ptr,
        .bytes_len = payload_len,
    };

    mark(&gc, &s.header);
    sweep(&gc);

    // The record block alone was the OLD number — the 4.6x under-report. The
    // honest number includes the byte payload the finaliser would free.
    try testing.expectEqual(@sizeOf(string_mod.String) + payload_len, gc.stats.last_live_bytes);
}

test "persistent bytes are measured but NOT folded into last_live (D-573)" {
    var gc = GcHeap.init(testing.allocator);
    defer gc.deinit();

    var waypoint: extern struct { header: HeapHeader = HeapHeader.init(.symbol), payload: u64 = 0 } = .{};
    try gc.registerPersistentMark(@ptrCast(&waypoint), 4096);
    try testing.expectEqual(@as(usize, 4096), gc.persistent_bytes);

    const a = try gc.alloc(Cell);
    a.* = .{ .header = HeapHeader.init(.symbol) };
    mark(&gc, &a.header);
    sweep(&gc);

    // The byte arm sizes against the SWEPT heap only; the waypoints' cost
    // belongs to the time-share arm (see sweep()'s comment — folding them in
    // was measured to starve the free pool and regress gc_alloc_rate ~11%).
    try testing.expectEqual(@sizeOf(Cell), gc.stats.last_live_bytes);

    gc.unregisterLastPersistentMark();
    try testing.expectEqual(@as(usize, 0), gc.persistent_bytes);
}
