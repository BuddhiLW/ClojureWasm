#!/usr/bin/env bash
# scripts/lib_cljw_bin.sh
#
# SSOT for "the cljw binary a script is about to probe must match the source
# it is being asked questions about".
#
# Source from the project root:
#
#     source "$(dirname "$0")/lib_cljw_bin.sh"
#
#   cljw_bin_stale BIN        — exit 0 when BIN is missing, or older than any
#                               file under `src/` / `build.zig` /
#                               `build.zig.zon`. Exit 1 when it is current.
#   cljw_bin_ensure BIN LABEL — rebuild when stale. LABEL names the caller in
#                               the "building cljw…" notice.
#   cljw_bin_require BIN LABEL— for callers that must NOT build: exit 1 with a
#                               build instruction when BIN is missing or stale.
#
# `find -newer` rather than `stat`: BSD and GNU `stat` disagree on the format
# flag, and the gate's primary host is macOS.
[[ -n "${LIB_CLJW_BIN_LOADED:-}" ]] && return 0
LIB_CLJW_BIN_LOADED=1

# shellcheck source=scripts/lib_build_lock.sh
source "${BASH_SOURCE[0]%/*}/lib_build_lock.sh"

# Sources whose change invalidates a built binary. `src/` covers the Zig
# runtime AND the bundled `.clj` (they are embedded at build time).
_cljw_bin_sources() {
  local s
  for s in src build.zig build.zig.zon; do
    [ -e "$s" ] && printf '%s\n' "$s"
  done
}

cljw_bin_stale() {
  local bin="${1:-zig-out/bin/cljw}"
  [ -x "$bin" ] || return 0
  local srcs
  srcs="$(_cljw_bin_sources)"
  [ -n "$srcs" ] || return 1
  # shellcheck disable=SC2086
  local newer
  newer="$(find $srcs -type f -newer "$bin" -print 2>/dev/null | head -1)"
  [ -n "$newer" ]
}

cljw_bin_ensure() {
  local bin="${1:-zig-out/bin/cljw}"
  local label="${2:-cljw}"
  if cljw_bin_stale "$bin"; then
    echo "${label}: building cljw (binary missing or older than src/)…" >&2
    with_build_lock zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
  fi
}

cljw_bin_require() {
  local bin="${1:-zig-out/bin/cljw}"
  local label="${2:-cljw}"
  if cljw_bin_stale "$bin"; then
    if [ -x "$bin" ]; then
      echo "${label}: $bin is STALE (older than src/) — rebuild: zig build -Dwasm -Doptimize=ReleaseSafe" >&2
    else
      echo "${label}: no binary at $bin — build it: zig build -Dwasm -Doptimize=ReleaseSafe" >&2
    fi
    exit 1
  fi
}
