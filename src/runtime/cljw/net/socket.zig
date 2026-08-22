// SPDX-License-Identifier: EPL-2.0
//! cljw.net — a TCP client stream, bound thinly to `std.Io.net`.
//!
//! Backend: impl-only
//! Impl deps: none
//! Clojure peer: cljw.net/connect
//!
//! Surface: `(cljw.net/connect host port)` → a `.host_instance` socket, then
//!          `(.write sock byte-array n)` → bytes written,
//!          `(.read  sock byte-array)`   → bytes read, or -1 at end of stream,
//!          `(.close sock)`              → nil (idempotent).
//!
//! This is a cljw-ORIGINAL surface, not a `java.net.Socket` emulation: it
//! exposes what `std.Io.net` does and leaves Java/JS/elisp reconciliation to the
//! caller's own adapter. The client mirror of the `.listen`/`.accept` pair
//! `src/app/nrepl.zig` already uses.
//!
//! Ownership: the `Stream` plus its reader/writer buffers live in one
//! gpa-allocated `SocketBox` whose pointer is `state[0]`; the box holds its own
//! `Io` so the ADR-0106 `host_finalise` hook can close a dropped socket at
//! sweep without a Runtime. `state` carries no `Value`, so no `host_trace`.
//!
//! Byte arrays are Value-erased (F-004 / F-005), so transfers convert
//! element-wise between the cljw array and a gpa scratch `[]u8`.
const std = @import("std");
const Runtime = @import("../../runtime.zig").Runtime;
const Env = @import("../../env.zig").Env;
const Value = @import("../../value/value.zig").Value;
const error_catalog = @import("../../error/catalog.zig");
const SourceLocation = @import("../../error/info.zig").SourceLocation;
const string_mod = @import("../../collection/string.zig");
const java_array = @import("../../collection/java_array.zig");
const host_instance = @import("../../host_instance.zig");
const type_descriptor = @import("../../type_descriptor.zig");

/// Reader/writer buffer size, and therefore the most one `.read` can return.
/// A `SocketBox` costs 2 * IO_BUF; a caller draining a multi-megabyte response
/// pays one host call per IO_BUF bytes.
const IO_BUF = 65536;

/// Heap carrier for one connected stream. Address-stable: `reader`/`writer`
/// borrow `rbuf`/`wbuf` in place, so the box must never be copied after `init`.
const SocketBox = struct {
    io: std.Io,
    stream: std.Io.net.Stream,
    reader: std.Io.net.Stream.Reader,
    writer: std.Io.net.Stream.Writer,
    closed: bool,
    rbuf: [IO_BUF]u8,
    wbuf: [IO_BUF]u8,
};

fn boxOf(recv: Value) *SocketBox {
    return @ptrFromInt(@as(usize, @intCast(host_instance.asHostInstance(recv).state[0])));
}

fn isSocket(v: Value) bool {
    return v.tag() == .host_instance and
        host_instance.asHostInstance(v).descriptor == &descriptor;
}

fn expectSocket(v: Value, loc: SourceLocation) !*SocketBox {
    if (!isSocket(v)) return error_catalog.raise(.net_arg_invalid, loc, .{ .detail = "the receiver must be a cljw.net socket" });
    const box = boxOf(v);
    if (box.closed) return error_catalog.raise(.net_socket_closed, loc, .{});
    return box;
}

/// `(cljw.net/connect host port)` — resolve `host`, open a TCP stream to it.
fn connectFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("cljw.net/connect", args, 2, loc);
    try ensureMethodTable(rt.gpa);
    if (!args[0].isString()) return error_catalog.raise(.net_arg_invalid, loc, .{ .detail = "the host must be a string" });
    const host = string_mod.asString(args[0]);
    const port_i = try error_catalog.expectI64(args[1], "port", loc);
    if (port_i < 0 or port_i > 65535) return error_catalog.raise(.net_arg_invalid, loc, .{ .detail = "the port must be an integer in 0..65535" });
    const port: u16 = @intCast(port_i);

    // An IP literal connects directly; a name goes through HostName.connect,
    // which races EVERY resolved address. Resolving to a single address strands
    // the common case where a name yields ::1 first and the peer is v4-only.
    const stream = if (std.Io.net.IpAddress.parse(host, port)) |parsed| blk: {
        var addr = parsed;
        break :blk std.Io.net.IpAddress.connect(&addr, rt.io, .{ .mode = .stream }) catch
            return error_catalog.raise(.net_connect_failed, loc, .{ .host = host, .port = port_i });
    } else |_| blk: {
        const name = std.Io.net.HostName.init(host) catch
            return error_catalog.raise(.net_arg_invalid, loc, .{ .detail = "the host is not a valid IP address or host name" });
        break :blk name.connect(rt.io, port, .{ .mode = .stream }) catch
            return error_catalog.raise(.net_connect_failed, loc, .{ .host = host, .port = port_i });
    };

    const box = rt.gpa.create(SocketBox) catch |e| {
        stream.close(rt.io);
        return e;
    };
    box.* = .{
        .io = rt.io,
        .stream = stream,
        .reader = undefined,
        .writer = undefined,
        .closed = false,
        .rbuf = undefined,
        .wbuf = undefined,
    };
    box.reader = box.stream.reader(box.io, &box.rbuf);
    box.writer = box.stream.writer(box.io, &box.wbuf);

    return host_instance.alloc(rt, &descriptor, .{ @intFromPtr(box), 0, 0, 0 });
}

/// `(.write sock ba n)` — write the first `n` bytes of `ba`. => bytes written.
fn writeMethod(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArityRange("cljw.net write", args, 2, 3, loc);
    const box = try expectSocket(args[0], loc);
    if (!java_array.isArray(args[1])) return error_catalog.raise(.net_arg_invalid, loc, .{ .detail = "the buffer must be a byte array" });

    const avail = java_array.alength(args[1]);
    const n: u32 = if (args.len == 3) blk: {
        const want = try error_catalog.expectI64(args[2], "n", loc);
        if (want < 0 or want > avail) return error_catalog.raise(.net_arg_invalid, loc, .{ .detail = "n must be between 0 and the buffer length" });
        break :blk @intCast(want);
    } else avail;

    const scratch = try rt.gpa.alloc(u8, n);
    defer rt.gpa.free(scratch);
    for (0..n) |i| {
        const v = try java_array.aget(args[1], @intCast(i), "cljw.net write", loc);
        scratch[i] = @truncate(@as(u64, @bitCast(@as(i64, v.asInteger()))));
    }

    box.writer.interface.writeAll(scratch) catch
        return error_catalog.raise(.net_io_failed, loc, .{ .op = "write" });
    box.writer.interface.flush() catch
        return error_catalog.raise(.net_io_failed, loc, .{ .op = "flush" });

    return Value.initInteger(@intCast(n));
}

/// `(.read sock ba)` — read available bytes into `ba`. => count, or -1 at EOF.
fn readMethod(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("cljw.net read", args, 2, loc);
    const box = try expectSocket(args[0], loc);
    if (!java_array.isArray(args[1])) return error_catalog.raise(.net_arg_invalid, loc, .{ .detail = "the buffer must be a byte array" });

    const cap = java_array.alength(args[1]);
    if (cap == 0) return Value.initInteger(0);

    const r = &box.reader.interface;
    if (r.buffered().len == 0) {
        _ = r.fillMore() catch |e| switch (e) {
            error.EndOfStream => return Value.initInteger(-1),
            else => return error_catalog.raise(.net_io_failed, loc, .{ .op = "read" }),
        };
    }
    const bytes = r.buffered();
    if (bytes.len == 0) return Value.initInteger(-1);

    const n: u32 = @intCast(@min(bytes.len, cap));
    for (0..n) |i| {
        _ = try java_array.aset(args[1], @intCast(i), Value.initInteger(bytes[i]), "cljw.net read", loc);
    }
    r.toss(n);
    return Value.initInteger(@intCast(n));
}

/// `(.close sock)` — close the stream. Idempotent; a closed socket stays closed.
fn closeMethod(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("cljw.net close", args, 1, loc);
    if (!isSocket(args[0])) return error_catalog.raise(.net_arg_invalid, loc, .{ .detail = "the receiver must be a cljw.net socket" });
    const box = boxOf(args[0]);
    if (!box.closed) {
        box.stream.close(box.io);
        box.closed = true;
    }
    return Value.nil_val;
}

/// ADR-0106 finaliser: close a socket the program dropped, then free the box.
fn finaliseSocket(infra: std.mem.Allocator, state: *[host_instance.STATE_WORDS]u64) void {
    if (state[0] == 0) return;
    const box: *SocketBox = @ptrFromInt(@as(usize, @intCast(state[0])));
    if (!box.closed) {
        box.stream.close(box.io);
        box.closed = true;
    }
    infra.destroy(box);
    state[0] = 0;
}

const MethodSpec = struct { name: []const u8, f: *const fn (*Runtime, *Env, []const Value, SourceLocation) anyerror!Value };

const METHODS = [_]MethodSpec{
    .{ .name = "write", .f = &writeMethod },
    .{ .name = "read", .f = &readMethod },
    .{ .name = "close", .f = &closeMethod },
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "cljw.net.Socket",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .parent = null,
    .meta = .nil_val,
};

/// Populate the socket method table. Idempotent, and called from `connectFn`
/// rather than `register` because `installAll` carries no allocator and a
/// socket can only reach a method through `connect`.
fn ensureMethodTable(gpa: std.mem.Allocator) !void {
    if (descriptor.method_table.len != 0) return;
    descriptor.host_finalise = &finaliseSocket;
    const entries = try gpa.alloc(type_descriptor.TypeDescriptor.MethodEntry, METHODS.len);
    for (METHODS, 0..) |m, i| {
        entries[i] = .{
            .protocol_name = "",
            .method_name = try gpa.dupe(u8, m.name),
            .method_val = Value.initBuiltinFn(m.f),
        };
    }
    descriptor.method_table = entries;
}

/// Create the `cljw.net` host namespace.
/// Called by `runtime/cljw/_host_api.zig::installAll`.
pub fn register(env: *Env) !void {
    const ns = try env.findOrCreateNs("cljw.net");
    _ = try env.intern(ns, "connect", Value.initBuiltinFn(&connectFn), null);
}
