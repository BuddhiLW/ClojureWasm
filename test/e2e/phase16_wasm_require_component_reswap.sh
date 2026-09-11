#!/usr/bin/env bash
# test/e2e/phase16_wasm_require_component_reswap.sh: CLJW-REQUIRE-COMPONENT-STALE.
#
# Re-requiring a component at the SAME path after its bytes changed must leave
# the target namespace mirroring the NEW export table: exports the new build
# dropped are unmapped (and a Var captured before the swap throws instead of
# calling the old instance), exports it kept keep their Var identity, and a Var
# the user defined in that namespace is never touched. Before the fix,
# swapping resource_counter.wasm (counter/increment/get) for
# two_export_component.wasm (echo-bool/echo-s32) left counter/increment/get
# interned, still calling (and keeping alive) the previous instance.
#
# The fixture swaps bytes inside cljw with clojure.java.io/copy; this script
# only owns the scratch directory the swapped file lives in.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }

"$BIN" --version | grep -q wasm || fail "cljw is not wasm-enabled ($("$BIN" --version))"

swap_dir="$(mktemp -d /tmp/cljw_reswap_XXXXXX)"
trap 'rm -rf "$swap_dir"' EXIT

out="$(CLJW_SWAP_DIR="$swap_dir" "$BIN" test/e2e/fixtures/wasm_require_component_reswap_probe.clj 2>&1)" \
  || fail "reswap fixture exited non-zero:
$out"

for marker in \
  "PASS gen1-exports" \
  "PASS gen1-tagged" \
  "PASS gen1-arglists-kept" \
  "PASS gen1-refer" \
  "PASS gen1-shadow-untagged" \
  "PASS gen1-call" \
  "PASS gen2-component-publics-exact" \
  "PASS gen2-user-defs-survive" \
  "PASS gen2-user-shadow-value" \
  "PASS gen2-dropped-unmapped" \
  "PASS gen2-refer-dropped-unmapped" \
  "PASS gen2-new-exports-call" \
  "PASS gen2-orphan-var-throws" \
  "PASS gen3-component-publics-exact" \
  "PASS gen3-user-helper-survives" \
  "PASS gen3-echo-unmapped" \
  "PASS gen4-var-identity-kept" \
  "PASS gen4-call-through-kept-var" \
  "PASS ns-directive-gen1" \
  "PASS ns-directive-gen2"; do
  grep -q "^$marker$" <<<"$out" || fail "missing: $marker
$out"
done
grep -q "^DONE$" <<<"$out" || fail "reswap fixture did not run to completion:
$out"

echo "OK: phase16_wasm_require_component_reswap (20 cases) green; dropped exports unmapped, kept Vars keep identity, user defs survive"
