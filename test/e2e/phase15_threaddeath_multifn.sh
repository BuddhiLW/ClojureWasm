#!/usr/bin/env bash
# test/e2e/phase15_threaddeath_multifn.sh
#
# Two host-class gaps that block clojure.test.check's non-random namespaces
# (CLJW-PROXY blockers 3 + 4):
#   - java.lang.ThreadDeath as a catch class: properties.cljc re-throws it so a
#     thrown thread-death is not swallowed. cljw is single-threaded and never
#     throws it; it must only ANALYSE. Under Error (a (catch Exception …) must
#     NOT match it).
#   - clojure.lang.MultiFn as an instance? target: clojure_test.cljc guards its
#     multimethod reporting on (instance? clojure.lang.MultiFn ct/report).

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }

check() { # check <expr> <expected> <label>
    local out
    set +e
    out=$("$BIN" -e "$1" 2>&1 | tail -n 1)
    set -e
    [[ "$out" == "$2" ]] || fail "$3: expected '$2', got '$out'"
    echo "PASS $3 -> $2"
}

# --- ThreadDeath: the guard analyses and the body value passes through ---
check '(try 1 (catch java.lang.ThreadDeath t (throw t)) (catch Throwable e 3))' \
      '1' threaddeath_guard_analyses
# simple name resolves too
check '(try :ok (catch ThreadDeath t :td))' ':ok' threaddeath_simple_name
# under Error, NOT Exception: a plain Exception catch does not shadow the type
check '(try :ran (catch java.lang.ThreadDeath t :td))' ':ran' threaddeath_isolated

# --- MultiFn: instance? / class / isa? ---
check '(do (defmulti mm identity) (instance? clojure.lang.MultiFn mm))' \
      'true'  multifn_instance_true
check '(instance? clojure.lang.MultiFn +)' 'false' multifn_instance_fn_false
check '(instance? clojure.lang.MultiFn 5)' 'false' multifn_instance_scalar_false
check '(do (defmulti mm2 identity) (= (class mm2) clojure.lang.MultiFn))' \
      'true'  multifn_class_identity
check '(do (defmulti mm3 identity) (isa? (class mm3) clojure.lang.IFn))' \
      'true'  multifn_isa_ifn

echo "OK phase15_threaddeath_multifn"
