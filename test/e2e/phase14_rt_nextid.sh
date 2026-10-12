#!/usr/bin/env bash
# test/e2e/phase14_rt_nextid.sh — `clojure.lang.RT/nextID` returns monotonic
# ints from the same per-Runtime counter `gensym` uses (JVM RT.nextID backs
# gensym), so ids never collide with gensym suffixes. Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
last_line() { printf '%s' "$1" | tail -1; }
check() {
  local got
  got="$("$BIN" -e "$2" 2>&1 || true)"
  [[ "$(last_line "$got")" == "$3" ]] || fail "$1: got '$got'"
  echo "PASS $1 -> $3"
}

check returns_int     '(integer? (clojure.lang.RT/nextID))' 'true'
check monotonic       '(let [a (clojure.lang.RT/nextID) b (clojure.lang.RT/nextID)] (< a b))' 'true'
check distinct_100    '(apply distinct? (repeatedly 100 #(clojure.lang.RT/nextID)))' 'true'
# Shared counter: a gensym between two ids sits strictly between them.
check shares_gensym   '(let [a (clojure.lang.RT/nextID) g (gensym) b (clojure.lang.RT/nextID)] [(- b a) (= (str g) (str "G__" (inc a)))])' '[2 true]'
check method_value    '(integer? (let [f clojure.lang.RT/nextID] (f)))' 'true'
got="$("$BIN" -e '(clojure.lang.RT/nextID 1)' 2>&1 || true)"
grep -qi 'arity\|wrong number' <<<"$got" || fail "arity: got '$got'"
echo "PASS arity -> arity error"

echo "OK — phase14_rt_nextid (6 cases) green"
