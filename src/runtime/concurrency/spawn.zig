// SPDX-License-Identifier: EPL-2.0
//! OS-thread spawn, gated on the build's threading mode. Threaded targets
//! spawn a worker; single-threaded targets (wasm32-wasi) return
//! `error.ThreadsUnsupported`, which each caller's existing spawn-failure
//! path turns into a clean runtime error. The `else` branch is comptime-dead
//! on single-threaded builds, so `std.Thread.spawn`'s single-threaded
//! `@compileError` is never reached.

const std = @import("std");
const builtin = @import("builtin");

pub fn spawn(comptime function: anytype, args: anytype) !std.Thread {
    return if (comptime builtin.single_threaded)
        error.ThreadsUnsupported
    else
        std.Thread.spawn(.{}, function, args);
}
