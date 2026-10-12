#!/usr/bin/env bash
# test/e2e/phase14_irecord_extend.sh — clojure.lang.IRecord is a recognised
# interface: every defrecord is an instance, and `(extend-protocol P
# clojure.lang.IRecord …)` serves every record without an impl of its own,
# ahead of an Object default (an interface impl outranks Object on the JVM).
# Surfaced by core.logic's IWalkTerm extension. Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
last_line() { printf '%s' "$1" | tail -1; }
check() { # name expr expected-last-line
  local got
  got="$("$BIN" -e "$2" 2>&1 || true)"
  [[ "$(last_line "$got")" == "$3" ]] || fail "$1: got '$got'"
  echo "PASS $1 -> $3"
}

check instance_record   '(do (defrecord R [a]) (instance? clojure.lang.IRecord (->R 1)))' 'true'
check instance_map      '(instance? clojure.lang.IRecord {:a 1})'                      'false'
check instance_deftype  '(do (deftype T []) (instance? clojure.lang.IRecord (T.)))'   'false'
check extend_record     '(do (defprotocol P (f [x])) (extend-protocol P clojure.lang.IRecord (f [x] [:rec (:a x)])) (defrecord R [a]) (f (->R 1)))' '[:rec 1]'
check beats_object      '(do (defprotocol P (f [x])) (extend-protocol P Object (f [x] :obj) clojure.lang.IRecord (f [x] :rec)) (defrecord R [a]) [(f (->R 1)) (f {}) (f 1)])' '[:rec :obj :obj]'
check own_impl_wins     '(do (defprotocol P (f [x])) (extend-protocol P clojure.lang.IRecord (f [x] :rec)) (defrecord R [a] P (f [x] :own)) (f (->R 1)))' ':own'
got="$("$BIN" -e '(do (defprotocol P (f [x])) (extend-protocol P clojure.lang.IRecord (f [x] :rec)) (f {}))' 2>&1 || true)"
grep -q "No implementation of method 'f'" <<<"$got" || fail "map_not_record: got '$got'"
echo "PASS map_not_record -> no impl"

echo "OK — phase14_irecord_extend (7 cases) green"
