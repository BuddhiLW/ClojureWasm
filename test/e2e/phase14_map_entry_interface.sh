#!/usr/bin/env bash
# test/e2e/phase14_map_entry_interface.sh: a deftype / reify may declare
# java.util.Map$Entry (core.logic's Pair does, core/logic.clj:74). It is a
# protocol_remap onto cljw's IMapEntry (-key/-val): (.getKey x) / (.getValue x)
# reach the type's own methods, and key / val / map-entry? treat the instance as
# a map entry, as clj does (clojure.core/key is (.getKey ^Map$Entry e)).
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

FIX=/tmp/phase14_map_entry_$$.clj
cat > "$FIX" <<'CLJ'
(deftype Pair [lhs rhs]
  clojure.lang.Counted
  (count [_] 2)
  java.util.Map$Entry
  (getKey [_] lhs)
  (getValue [_] rhs)
  Object
  (toString [_] (str "(" lhs " . " rhs ")")))
(def p (Pair. :a 1))
(println "getKey" (.getKey p))
(println "getValue" (.getValue p))
(println "key" (key p))
(println "val" (val p))
(println "entry?" (map-entry? p))
(println "instance" (instance? java.util.Map$Entry p))
(println "str" (str p))
(println "native" (key (first {:x 9})) (val (first {:x 9})))
(println "vec-key" (try (key [:k :v]) (catch ClassCastException _ :cce)))
(println "plain?" (map-entry? (reify Object (toString [_] "x"))))
(def r (reify java.util.Map$Entry (getKey [_] :rk) (getValue [_] :rv)))
(println "reify" (key r) (val r) (.getKey r))
CLJ
out="$("$BIN" "$FIX" 2>&1)"
rm -f "$FIX"
line() { printf '%s\n' "$out" | grep "^$1 " | tail -1; }
assert_eq 'getKey'   "$(line getKey)"   'getKey :a'
assert_eq 'getValue' "$(line getValue)" 'getValue 1'
assert_eq 'key'      "$(line key)"      'key :a'
assert_eq 'val'      "$(line val)"      'val 1'
assert_eq 'entry?'   "$(line 'entry?')" 'entry? true'
assert_eq 'instance' "$(line instance)" 'instance true'
assert_eq 'str'      "$(line str)"      'str (:a . 1)'
assert_eq 'native'   "$(line native)"   'native :x 9'
assert_eq 'vec-key'  "$(line vec-key)"  'vec-key :cce'
assert_eq 'plain?'   "$(line 'plain?')" 'plain? false'
assert_eq 'reify'    "$(line reify)"    'reify :rk :rv :rk'

# The bare nested name after an :import resolves too.
BARE="$("$BIN" -e '(ns t (:import (java.util Map$Entry))) (deftype E [k v] Map$Entry (getKey [_] k) (getValue [_] v)) (let [e (E. 1 2)] [(key e) (val e)])' 2>&1 | tail -1)"
assert_eq 'bare-import' "$BARE" '[1 2]'
echo "phase14_map_entry_interface: OK"
