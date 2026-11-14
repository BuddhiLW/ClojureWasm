// SPDX-License-Identifier: EPL-2.0
//! Unit tests for `gc_heap.zig`: init/deinit, the live-heap ceiling, pinning,
//! allocation accounting, the global heap lock under real threads, and the
//! D-566 mutator check.

const std = @import("std");
const testing = std.testing;

const gc_heap_mod = @import("gc_heap.zig");
const heap_header = @import("../value/heap_header.zig");
const value_mod = @import("../value/value.zig");
const io_default = @import("../concurrency/io_default.zig");
const root_set_mod = @import("root_set.zig");

const GcHeap = gc_heap_mod.GcHeap;
const HeapHeader = heap_header.HeapHeader;
const Value = value_mod.Value;
const Cell = extern struct { header: HeapHeader, payload: u64 = 0 };

test "GcHeap.init / deinit on an empty heap" {
    var gc = GcHeap.init(testing.allocator);
    defer gc.deinit();

    try testing.expectEqual(@as(usize, 0), gc.allocations.items.len);
    try testing.expectEqual(@as(usize, 0), gc.permanent_roots.items.len);
    try testing.expectEqual(@as(usize, 0), gc.stats.bytes_allocated);
    try testing.expectEqual(@as(u64, 0), gc.stats.alloc_count);
    try testing.expectEqual(@as(usize, gc_heap_mod.default_gc_threshold_bytes), gc.threshold_bytes);
}

test "D-352: heap_ceiling refuses allocations past the live-byte cap" {
    var gc = GcHeap.init(testing.allocator);
    defer gc.deinit();
    gc.heap_ceiling = 200; // bytes: a handful of cells, then refuse
    var refused = false;
    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        // No hook installed, so the bare error.OutOfMemory surfaces.
        _ = gc.alloc(Cell) catch {
            refused = true;
            break;
        };
    }
    try testing.expect(refused);
    // An unmetered heap keeps allocating past the old ceiling.
    gc.heap_ceiling = null;
    _ = try gc.alloc(Cell);
}

test "GcHeap.pin appends to permanent_roots; unpin removes first match" {
    var gc = GcHeap.init(testing.allocator);
    defer gc.deinit();

    const a = Value.initInteger(42);
    const b = Value.initInteger(7);
    try gc.pin(a);
    try gc.pin(b);
    try testing.expectEqual(@as(usize, 2), gc.permanent_roots.items.len);

    try testing.expect(gc.unpin(a));
    try testing.expectEqual(@as(usize, 1), gc.permanent_roots.items.len);
    try testing.expect(gc.unpin(b));
    try testing.expectEqual(@as(usize, 0), gc.permanent_roots.items.len);

    try testing.expect(!gc.unpin(a)); // already removed
}

test "GcHeap.alloc tracks bytes + count + bytes_since_last_gc" {
    var gc = GcHeap.init(testing.allocator);
    defer gc.deinit();

    const c1 = try gc.alloc(Cell);
    c1.* = .{ .header = HeapHeader.init(.symbol) };
    try testing.expectEqual(@as(usize, 1), gc.allocations.items.len);
    try testing.expectEqual(@as(usize, @sizeOf(Cell)), gc.stats.bytes_allocated);
    try testing.expectEqual(@as(u64, 1), gc.stats.alloc_count);
    try testing.expectEqual(@as(usize, @sizeOf(Cell)), gc.bytes_since_last_gc);

    const c2 = try gc.alloc(Cell);
    c2.* = .{ .header = HeapHeader.init(.vector) };
    try testing.expectEqual(@as(usize, 2), gc.allocations.items.len);
    try testing.expectEqual(@as(usize, 2 * @sizeOf(Cell)), gc.stats.bytes_allocated);
    try testing.expectEqual(@as(u64, 2), gc.stats.alloc_count);
}

test "concurrent alloc through the global heap lock is race-free (ADR-0090 §2)" {
    // gc_mutex must serialize alloc across real OS threads. Set io_default to
    // a THREADED io for real mutex blocking, then restore it.
    const per_thread = 500;
    const n_threads = 4;

    const saved_io = io_default.get();
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    defer io_default.set(saved_io); // runs before threaded.deinit (LIFO)
    io_default.set(threaded.io());

    var gc = GcHeap.init(testing.allocator);
    defer gc.deinit();

    const Worker = struct {
        fn run(g: *GcHeap) void {
            // D-566: a non-owner thread allocates only as a registered worker.
            var tx: ?*anyopaque = null;
            var ctx = root_set_mod.workerContext(&tx);
            root_set_mod.registerThread(&ctx) catch return;
            defer root_set_mod.unregisterThread(&ctx);
            var i: usize = 0;
            while (i < per_thread) : (i += 1) {
                const c = g.alloc(Cell) catch return;
                c.* = .{ .header = HeapHeader.init(.symbol) };
            }
        }
    };

    var threads: [n_threads]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{&gc});
    for (&threads) |t| t.join();

    // Every alloc landed exactly once.
    try testing.expectEqual(@as(usize, n_threads * per_thread), gc.allocations.items.len);
    try testing.expectEqual(@as(u64, n_threads * per_thread), gc.stats.alloc_count);
}

test "mutatorAllowed: the stamping thread and registered workers may alloc, a foreign unregistered thread may not (D-566)" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    var gc = GcHeap.init(testing.allocator);
    defer gc.deinit();
    try testing.expect(gc.mutatorAllowed());
    try testing.expect(root_set_mod.analysisMutatorAllowed());

    const Probe = struct {
        var unregistered: bool = true;
        var unregistered_analysis: bool = true;
        var registered: bool = false;
        fn run(g: *const GcHeap) void {
            unregistered = g.mutatorAllowed();
            unregistered_analysis = root_set_mod.analysisMutatorAllowed();
            var tx: ?*anyopaque = null;
            var ctx = root_set_mod.workerContext(&tx);
            root_set_mod.registerThread(&ctx) catch return;
            defer root_set_mod.unregisterThread(&ctx);
            registered = g.mutatorAllowed();
        }
    };
    Probe.unregistered = true;
    Probe.unregistered_analysis = true;
    Probe.registered = false;
    const t = try std.Thread.spawn(.{}, Probe.run, .{&gc});
    t.join();
    try testing.expect(!Probe.unregistered);
    try testing.expect(!Probe.unregistered_analysis);
    try testing.expect(Probe.registered);
}

test "GcHeap.alloc returned pointer aliases the live-list HeapHeader" {
    var gc = GcHeap.init(testing.allocator);
    defer gc.deinit();

    const c = try gc.alloc(Cell);
    c.* = .{ .header = HeapHeader.init(.list) };

    const rec = gc.allocations.items[0];
    const hdr_via_cast: *HeapHeader = @ptrCast(c);
    try testing.expectEqual(rec.header, hdr_via_cast);
    try testing.expectEqual(@as(u8, @intFromEnum(value_mod.HeapTag.list)), rec.header.tag);
    try testing.expectEqual(@sizeOf(Cell), rec.allocation.size);
}

test "GcHeap.allocWithTail refuses an unrepresentable record size before allocating" {
    if (@bitSizeOf(usize) != 64) return;
    var gc = GcHeap.init(testing.allocator);
    defer gc.deinit();
    const max_cell_bytes = @import("gc_types.zig").max_cell_bytes;
    try testing.expectError(error.OutOfMemory, gc.allocWithTail(Cell, max_cell_bytes));
    try testing.expectEqual(@as(usize, 0), gc.allocations.items.len);
    try testing.expectEqual(@as(usize, 0), gc.stats.bytes_allocated);
    try testing.expectEqual(@as(usize, 0), gc.committedBytes());
}

test "GcHeap retains exact free metadata for small, large and over-aligned cells" {
    const page_heap = @import("page_heap.zig");
    const sweep = @import("mark_sweep.zig").sweep;
    const LargeCell = extern struct { header: HeapHeader, payload: [5000]u8 };
    const AlignedCell = extern struct { header: HeapHeader align(64), payload: u64 };
    const large_size = @sizeOf(LargeCell) + 17;
    try testing.expect(page_heap.isSmall(@sizeOf(Cell), std.mem.Alignment.of(Cell)));
    try testing.expect(!page_heap.isSmall(large_size, std.mem.Alignment.of(LargeCell)));
    try testing.expect(!page_heap.isSmall(@sizeOf(AlignedCell), std.mem.Alignment.of(AlignedCell)));
    // Exercise both decoders: sweep and deinit of still-live allocations.
    for ([_]bool{ true, false }) |do_sweep| {
        var gc = GcHeap.init(testing.allocator);
        defer gc.deinit();
        const small = try gc.alloc(Cell);
        small.* = .{ .header = HeapHeader.init(.symbol) };
        const large = try gc.allocWithTail(LargeCell, 17);
        large.* = .{ .header = HeapHeader.init(.symbol), .payload = @splat(0) };
        const aligned = try gc.alloc(AlignedCell);
        aligned.* = .{ .header = HeapHeader.init(.symbol), .payload = 0 };
        try testing.expectEqual(large_size, gc.allocations.items[1].allocation.size);
        try testing.expectEqual(std.mem.Alignment.@"64", gc.allocations.items[2].allocation.alignment);
        const allocated = gc.stats.bytes_allocated;
        if (do_sweep) {
            large.header.gc_and_lock.gc_mark = 1;
            sweep(&gc);
            try testing.expectEqual(@as(usize, 1), gc.allocations.items.len);
            try testing.expectEqual(&large.header, gc.allocations.items[0].header);
            try testing.expectEqual(large_size, gc.stats.last_live_bytes);
            try testing.expectEqual(allocated - large_size, gc.stats.bytes_freed);
            sweep(&gc);
            try testing.expectEqual(@as(usize, 0), gc.allocations.items.len);
            try testing.expectEqual(@as(usize, 0), gc.large_live_bytes);
            try testing.expectEqual(allocated, gc.stats.bytes_freed);
        }
    }
}

test "Stats struct shape" {
    const s = gc_heap_mod.Stats{};
    try testing.expectEqual(@as(usize, 0), s.bytes_allocated);
    try testing.expectEqual(@as(usize, 0), s.bytes_freed);
    try testing.expectEqual(@as(u64, 0), s.alloc_count);
    try testing.expectEqual(@as(u64, 0), s.collect_count);
    try testing.expectEqual(@as(u64, 0), s.sweep_count);
    try testing.expectEqual(@as(usize, 0), s.last_live_bytes);
}
