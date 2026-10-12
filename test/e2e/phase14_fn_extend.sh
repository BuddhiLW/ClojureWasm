#!/usr/bin/env bash
# test/e2e/phase14_fn_extend.sh — clojure.lang.Fn (the AFunction marker every
# compiled fn implements) resolves as a class: `(extend-type clojure.lang.Fn …)`
# distributes over the fn tags, and `instance?` agrees. A MultiFn or an
# invocable keyword/map is IFn but NOT Fn, as in clj. Surfaced by core.logic's
# Inc stream (`(extend-type clojure.lang.Fn IBind … IMPlus … ITake …)`). Layer 2.
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

check instance_fn        '(instance? clojure.lang.Fn (fn [] 1))'      'true'
check instance_builtin   '(instance? clojure.lang.Fn inc)'            'true'
check instance_keyword   '(instance? clojure.lang.Fn :k)'             'false'
check instance_multi     '(do (defmulti m identity) (instance? clojure.lang.Fn m))' 'false'
check extend_fn          '(do (defprotocol P (f [x])) (extend-type clojure.lang.Fn P (f [x] (x))) (f (fn [] :called)))' ':called'
check extend_builtin     '(do (defprotocol P (f [x])) (extend-type clojure.lang.Fn P (f [x] :fn)) (f inc))' ':fn'
check multi_sections     '(do (defprotocol A (a [x])) (defprotocol B (b [x])) (extend-type clojure.lang.Fn A (a [x] 1) B (b [x] 2)) (let [g (fn [] 0)] [(a g) (b g)]))' '[1 2]'
got="$("$BIN" -e '(do (defprotocol P (f [x])) (extend-type clojure.lang.Fn P (f [x] :fn)) (f :k))' 2>&1 || true)"
grep -q "No implementation of method 'f'" <<<"$got" || fail "keyword_not_fn: got '$got'"
echo "PASS keyword_not_fn -> no impl"

echo "OK — phase14_fn_extend (8 cases) green"
