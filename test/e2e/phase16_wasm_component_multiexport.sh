#!/usr/bin/env bash
# test/e2e/phase16_wasm_component_multiexport.sh — D-567.
#
# cljw's headline feature is "require a Wasm component as a namespace". A
# namespace with one function is not a namespace, and until 2026-08-04 nobody
# had checked: both component fixtures in the tree (greet, resource_counter)
# export exactly one function, so a component with TWO exports had never been
# loaded.
#
# It does not load. `zwasm` rejects any component with >= 2 exports with
# InvalidSort — engine-side, reproduced with zwasm's own CLI, root cause located
# in its component_funcs index-space accounting (see fixtures/wasm/README_echo.md).
#
# This test PINS THE GAP rather than pretending it away: it asserts the failure
# is the clean catchable one (not a panic, not a hang) and prints what the
# fixture is for. When zwasm D-527 lands, this flips to asserting the exports
# and the ADR-0135 marshalling table — which is what discharges D-404's
# "BLOCKED on a typed component FIXTURE".
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }

F=test/e2e/fixtures/wasm
[ -f "$F/echo.component.wasm" ]      || fail "the typed fixture is missing"
[ -f "$F/two_export_component.wasm" ] || fail "the minimal reproduction is missing"

# The single-export control still loads — so the failure below is about export
# COUNT, not about components in general.
got="$("$BIN" -e '(println (count (wasm/component-exports "test/e2e/fixtures/wasm/greet_component.wasm")))' 2>&1 | head -1)"
[[ "$got" == "1" ]] || fail "single-export control did not load: got '$got'"
echo "PASS single-export-control -> $got"

# Two exports: a catchable cljw error, not a panic and not a hang. `|| true`
# because a non-zero exit is the expected shape here; what matters is WHICH
# failure.
out="$("$BIN" -e '(try (wasm/component-exports "test/e2e/fixtures/wasm/two_export_component.wasm") (catch Throwable e (println "CAUGHT")))' 2>&1 || true)"
echo "$out" | grep -qiE 'failed to compile or instantiate|CAUGHT' \
  || fail "two-export component failed in an unexpected way (want a clean load error): $out"
echo "$out" | grep -qiE 'panic|segmentation|abort' \
  && fail "two-export component crashed rather than erroring: $out"
echo "PASS two-export-gap-is-a-clean-error (D-567; zwasm D-527)"

# Same for the full typed fixture, so the pin covers the artifact D-404 wants.
out="$("$BIN" -e '(try (wasm/component-exports "test/e2e/fixtures/wasm/echo.component.wasm") (catch Throwable e (println "CAUGHT")))' 2>&1 || true)"
echo "$out" | grep -qiE 'panic|segmentation|abort' \
  && fail "typed fixture crashed rather than erroring: $out"
echo "PASS typed-fixture-gap-is-a-clean-error"

echo "OK — phase16_wasm_component_multiexport (3 cases) green — the gap is pinned, not hidden"
