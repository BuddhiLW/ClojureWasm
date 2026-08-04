// SPDX-License-Identifier: EPL-2.0
//! Filesystem + chained require resolvers (ADR-0084, D-158).
//!
//! `filesystemResolver` maps a namespace symbol to a `.clj`/`.cljc` file on the
//! `rt.load_paths` classpath (`foo.bar-baz` → `foo/bar_baz.clj`, JVM munge) and
//! reads its source. `chainedResolver` tries the bootstrap-embedded resolver
//! FIRST (so clojure.core / clojure.test can never be shadowed by a stray
//! on-disk file), then the filesystem. The CLI installs `chainedResolver` for
//! `cljw run` / REPL; the test/embedded path keeps `embeddedResolver` so a stray
//! `.clj` in a test's cwd cannot perturb a unit/diff test.
//!
//! Backend: impl-only (filesystem read + ns→path munge)
//! Impl deps: file_io
//! Clojure peer: none (this is the require machinery, not a var)

const std = @import("std");
const Runtime = @import("../runtime/runtime.zig").Runtime;
const ResolvedSource = @import("../runtime/runtime.zig").ResolvedSource;
const file_io = @import("../runtime/file_io.zig");
const error_catalog = @import("../runtime/error/catalog.zig");
const bootstrap = @import("bootstrap.zig");

/// True when `ns_name` has an EMPTY dot-separated segment — a leading dot, a
/// trailing dot, or a doubled dot. Such a name is not writable through the
/// reader (`(quote ..a.b)` does not parse), so it can only arrive via
/// `(require (symbol s))` with a computed name.
///
/// It must not resolve (D-343). The munge maps `.` → `/` per character, so
/// `..a.b` becomes `//a/b`, and once that is joined onto a load path POSIX
/// collapses the doubled slash — making `..a.b`, `.a.b` and `a..b` silent
/// aliases for `a.b` under some load-path shapes. JVM Clojure refuses: its
/// classloader looks for the literal resource `//a/b.clj` and does not find it
/// (verified against clj 2026-08-04, which reports
/// "Could not locate //secret/leak.clj … on classpath").
///
/// Checked at the munge boundary rather than by normalising the path, because
/// the property we want is about the NAME — an empty segment is not a valid
/// namespace segment — and a path-level check would depend on how each host
/// collapses separators.
fn hasEmptySegment(ns_name: []const u8) bool {
    if (ns_name.len == 0) return true;
    if (ns_name[0] == '.' or ns_name[ns_name.len - 1] == '.') return true;
    return std.mem.find(u8, ns_name, "..") != null;
}

/// Munge a namespace name into its relative resource path: `.` → `/`, `-` → `_`
/// (JVM `clojure.lang.RT/resourceName` convention). Allocated in `arena`.
/// Returns null for a name with an empty segment — see `hasEmptySegment`.
fn mungeNsToPath(arena: std.mem.Allocator, ns_name: []const u8) !?[]u8 {
    if (hasEmptySegment(ns_name)) return null;
    const buf = try arena.alloc(u8, ns_name.len);
    for (ns_name, 0..) |c, i| buf[i] = switch (c) {
        '.' => '/',
        '-' => '_',
        else => c,
    };
    return buf;
}

/// Resolve `ns_name` to source by searching `rt.load_paths` for
/// `<dir>/<munged>.clj` then `.cljc`. Returns null when no file is found (so the
/// chain / caller maps to `lib_not_found`); raises `lib_load_failed` when a file
/// exists but cannot be read. Source + label live in `rt.load_arena`.
pub fn filesystemResolver(rt: *Runtime, ns_name: []const u8) anyerror!?ResolvedSource {
    const arena = rt.load_arena.allocator();
    // An empty-segment name resolves to nothing, like clj's classloader — the
    // caller maps null to `lib_not_found`.
    const rel = (try mungeNsToPath(arena, ns_name)) orelse return null;
    const exts = [_][]const u8{ ".clj", ".cljc" };
    for (rt.load_paths) |dir| {
        for (exts) |ext| {
            const path = try std.fmt.allocPrint(arena, "{s}/{s}{s}", .{ dir, rel, ext });
            const src = file_io.readAll(rt.io, arena, path) catch |err| switch (err) {
                // Not at this dir/ext — keep searching.
                error.FileNotFound, error.NotDir, error.BadPathName => continue,
                // Found but unreadable (permissions, I/O) — distinct from "not found".
                else => return error_catalog.raise(.lib_load_failed, .{}, .{
                    .ns = ns_name,
                    .detail = @errorName(err),
                }),
            };
            return .{ .source = src, .label = path, .from_filesystem = true };
        }
    }
    return null;
}

/// Embedded-FIRST chain: bootstrap nses (clojure.core/test/…) win, then the
/// filesystem. Installed by the CLI for `run` / REPL.
pub fn chainedResolver(rt: *Runtime, ns_name: []const u8) anyerror!?ResolvedSource {
    if (try bootstrap.embeddedResolver(rt, ns_name)) |r| return r;
    return filesystemResolver(rt, ns_name);
}

/// Install the embedded-first chain onto `rt.require_resolver`.
pub fn installChained(rt: *Runtime) void {
    rt.require_resolver = chainedResolver;
}

const testing = std.testing;

test "mungeNsToPath maps . to / and - to _" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("foo/bar_baz", (try mungeNsToPath(a, "foo.bar-baz")).?);
    try testing.expectEqualStrings("clojure/string", (try mungeNsToPath(a, "clojure.string")).?);
    try testing.expectEqualStrings("a", (try mungeNsToPath(a, "a")).?);
    try testing.expectEqualStrings("my_app/core_test", (try mungeNsToPath(a, "my-app.core-test")).?);
}

test "mungeNsToPath refuses an empty namespace segment (D-343)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A leading / trailing / doubled dot yields an empty path segment, which
    // POSIX collapses — making these silent aliases for the well-formed name.
    // clj's classloader refuses them; so do we.
    try testing.expect((try mungeNsToPath(a, "..demo.math")) == null);
    try testing.expect((try mungeNsToPath(a, ".demo.math")) == null);
    try testing.expect((try mungeNsToPath(a, "demo..math")) == null);
    try testing.expect((try mungeNsToPath(a, "demo.math.")) == null);
    try testing.expect((try mungeNsToPath(a, "...")) == null);
    try testing.expect((try mungeNsToPath(a, "")) == null);
    // …and the well-formed neighbours still munge, so the check is not
    // over-broad: a `-` is not a segment separator, and a single interior dot
    // is exactly what a namespace is made of.
    try testing.expectEqualStrings("demo/math", (try mungeNsToPath(a, "demo.math")).?);
    try testing.expectEqualStrings("demo__math", (try mungeNsToPath(a, "demo--math")).?);
}
