#!/usr/bin/env bash
# test/e2e/phase14_dot_static_class.sh — the `.` special form with a CLASS
# receiver is static access, as on the JVM: `(. Class member args…)` and
# `(. Class (member args…))` behave like `(Class/member args…)`, for every
# class whose statics cljw models (methods and zero-arg static field reads),
# and an unmodelled `clojure.lang.*` member keeps the AD-008 deferred rewrite.
# Surfaced by core.logic's `(. clojure.lang.RT (nextID))`. Layer 2.
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

check flat_static_method      '(. Math abs -3)'                       '3'
check list_static_method      '(. Math (abs -3))'                     '3'
check fqcn_static_method      '(. java.lang.Math (max 1 2))'          '2'
check clojure_lang_class      '(. clojure.lang.Util (identical :a :a))' 'true'
check static_field_flat       '(= (. Math PI) Math/PI)'               'true'
check static_field_list       '(= (. Integer (MAX_VALUE)) Integer/MAX_VALUE)' 'true'
check rt_nextid_list          '(integer? (. clojure.lang.RT (nextID)))' 'true'
check rt_nextid_flat          '(integer? (. clojure.lang.RT nextID))'  'true'
# A local named like a class is an instance receiver, never the class.
check local_shadows_class     '(let [Math "abc"] (. Math (length)))'  '3'
# Instance receivers are untouched.
check instance_receiver       '(. "abcd" (substring 1 3))'           '"bc"'
# Unmodelled clojure.lang.* member: the fn defines; the call errors loudly.
check deferred_defines        '(do (defn f [] (. clojure.lang.RT (baseLoader))) :ok)' ':ok'
got="$("$BIN" -e '(do (defn f [] (. clojure.lang.RT (baseLoader))) (f))' 2>&1 || true)"
grep -q 'clojure.lang.RT/baseLoader is not supported' <<<"$got" || fail "deferred_raises: got '$got'"
echo "PASS deferred_raises -> feature_not_supported"

echo "OK — phase14_dot_static_class (13 cases) green"
