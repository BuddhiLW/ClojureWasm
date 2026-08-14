#!/usr/bin/env bash
# test/e2e/phase15_require_fs.sh — filesystem `require` (D-158, ADR-0084).
# `-cp <dir>` / $CLJW_PATH let `require` load a lib's `.clj` source off disk;
# embedded nses (clojure.core/test) win the chain; cycles raise; missing libs
# raise lib_not_found. The capstone: a disk test-ns requiring clojure.test +
# another disk lib and running its deftest suite. Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
CP="test/e2e/fixtures/cljwlib"
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

# load a disk lib via -cp + alias
assert_eq 'cp-load'  "$("$BIN" -cp "$CP" -e '(require (quote [demo.math :as m])) (m/square 7)' 2>&1 | tail -1)" '49'
# CLJW_PATH env path
assert_eq 'env-path' "$(CLJW_PATH="$CP" "$BIN" -e '(require (quote [demo.math :as m])) (m/cube 4)' 2>&1 | tail -1)" '64'
# capstone: a disk test-ns (requires clojure.test + demo.math) + run its suite
assert_eq 'run-suite' "$("$BIN" -cp "$CP" -e '(require (quote demo.math-test)) (let [s (clojure.test/run-tests (quote demo.math-test))] [(:pass s) (:fail s)])' 2>&1 | tail -1)" '[4 0]'
# missing lib -> lib_not_found
# 2 occurrences: message line + the source-window caret (print.zig's
# intended form; D-555 restored the vm's loc fidelity on op_require).
assert_eq 'missing'  "$("$BIN" -cp "$CP" -e '(require (quote no.such.lib))' 2>&1 | grep -c 'Could not locate')" '2'
# embedded clojure.string NOT shadowed by a stray on-disk file
SHADOW="$(mktemp -d)"; mkdir -p "$SHADOW/clojure"; printf '(ns clojure.string) (def upper-case :HIJACKED)\n' > "$SHADOW/clojure/string.clj"
assert_eq 'no-shadow' "$("$BIN" -cp "$SHADOW" -e '(clojure.string/upper-case "hi")' 2>&1 | tail -1)" '"HI"'
rm -rf "$SHADOW"
# cycle a->b->a -> Cyclic load dependency
CYC="$(mktemp -d)"; mkdir -p "$CYC/cyc"
printf '(ns cyc.a (:require [cyc.b]))\n' > "$CYC/cyc/a.clj"
printf '(ns cyc.b (:require [cyc.a]))\n' > "$CYC/cyc/b.clj"
# 2 occurrences: message + caret (same D-555 loc-fidelity form as 'missing').
assert_eq 'cycle' "$("$BIN" -cp "$CYC" -e '(require (quote cyc.a))' 2>&1 | grep -c 'Cyclic load dependency')" '2'
rm -rf "$CYC"

# --- .cljw extension resolution (ADR-0189) ---
EXT="$(mktemp -d)"; mkdir -p "$EXT/ext"
# a lone .cljw lib resolves
printf '(ns ext.only) (def who :from-cljw)\n' > "$EXT/ext/only.cljw"
assert_eq 'cljw-only'  "$("$BIN" -cp "$EXT" -e '(require (quote ext.only)) ext.only/who' 2>&1 | tail -1)" ':from-cljw'
# .cljw WINS over a sibling .clj and .cljc at the same root (probe order)
printf '(ns ext.both) (def who :from-cljw)\n'  > "$EXT/ext/both.cljw"
printf '(ns ext.both) (def who :from-clj)\n'   > "$EXT/ext/both.clj"
printf '(ns ext.both) (def who :from-cljc)\n'  > "$EXT/ext/both.cljc"
assert_eq 'cljw-wins'   "$("$BIN" -cp "$EXT" -e '(require (quote ext.both)) ext.both/who' 2>&1 | tail -1)" ':from-cljw'
# .clj still wins over .cljc when no .cljw is present (no regression)
printf '(ns ext.pair) (def who :from-clj)\n'   > "$EXT/ext/pair.clj"
printf '(ns ext.pair) (def who :from-cljc)\n'  > "$EXT/ext/pair.cljc"
assert_eq 'clj-over-cljc' "$("$BIN" -cp "$EXT" -e '(require (quote ext.pair)) ext.pair/who' 2>&1 | tail -1)" ':from-clj'
# a .cljw lib can require a .clj lib and vice versa — the extension is not a barrier
printf '(ns ext.mixed (:require [ext.pair :as p])) (def who p/who)\n' > "$EXT/ext/mixed.cljw"
assert_eq 'cljw-requires-clj' "$("$BIN" -cp "$EXT" -e '(require (quote ext.mixed)) ext.mixed/who' 2>&1 | tail -1)" ':from-clj'
# an EARLIER classpath root wins even when a later root holds the .cljw —
# roots are searched outermost-first (JVM classpath semantics), extension
# order applies WITHIN a root, never across them.
EXT2="$(mktemp -d)"; mkdir -p "$EXT2/ext"
printf '(ns ext.rooted) (def who :from-root2-cljw)\n' > "$EXT2/ext/rooted.cljw"
printf '(ns ext.rooted) (def who :from-root1-clj)\n'  > "$EXT/ext/rooted.clj"
assert_eq 'root-beats-ext' "$("$BIN" -cp "$EXT:$EXT2" -e '(require (quote ext.rooted)) ext.rooted/who' 2>&1 | tail -1)" ':from-root1-clj'
rm -rf "$EXT" "$EXT2"

echo "OK — phase15_require_fs (11 cases) green"
