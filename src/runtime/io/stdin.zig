// SPDX-License-Identifier: EPL-2.0
//! One portable "read a chunk from process stdin" primitive, shared by the
//! `*in*` readers (text_io, host_stream), via `std.Io.File`.

const std = @import("std");

/// Read up to `buf.len` bytes from stdin into `buf`. Returns bytes read
/// (0 = EOF).
pub fn readChunk(io: std.Io, buf: []u8) std.Io.File.ReadStreamingError!usize {
    return std.Io.File.stdin().readStreaming(io, &.{buf});
}
