#!/usr/bin/env bash
# test/e2e/phase15_proxy_threadlocal.sh
#
# clojure.core/proxy over the REGISTERED proxyable base classes (D-298).
# cljw has no JVM class hierarchy to extend, so `proxy` is closed per build:
# ThreadLocal is entry 1, realized as a memoized one-slot cell in cljw.proxy
# (single-threaded wasm — .get runs initialValue once then caches; .set
# overwrites; .remove clears so the next .get re-inits). An unregistered base
# is a compile-time error, not a deep JVM class extension.
#
# This is the blocker-2 gate for clojure.test.check.random on cljw, which is
# the generator engine malli.generator (and every schema property suite) needs.

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

# --- initialValue: run once on first get, then the value is cached ---
check '(let [tl (proxy [ThreadLocal] [] (initialValue [] 42))] (.get tl))' \
      '42' proxy_tl_initialValue
check '(let [c (atom 0) tl (proxy [ThreadLocal] [] (initialValue [] (swap! c inc)))] [(.get tl) (.get tl) @c])' \
      '[1 1 1]' proxy_tl_caches_initialValue

# --- .set overwrites the cell ---
check '(let [tl (proxy [ThreadLocal] [] (initialValue [] 1))] (.set tl 9) (.get tl))' \
      '9' proxy_tl_set

# --- .remove clears; the next .get re-runs initialValue ---
check '(let [c (atom 0) tl (proxy [ThreadLocal] [] (initialValue [] (swap! c inc)))] [(.get tl) (do (.remove tl) (.get tl)) @c])' \
      '[1 2 2]' proxy_tl_remove_reinits

# --- fully-qualified base name resolves through the same registry entry ---
check '(let [tl (proxy [java.lang.ThreadLocal] [] (initialValue [] :ok))] (.get tl))' \
      ':ok' proxy_tl_fqcn

# --- the .get/.set cycle test.check.random rides (get, split, set) ---
check '(let [a (atom 0) tl (proxy [ThreadLocal] [] (initialValue [] (swap! a inc) @a))] (let [v (.get tl)] (.set tl (* 10 v)) [v (.get tl)]))' \
      '[1 10]' proxy_tl_random_pattern

# --- an UNREGISTERED base is a compile-time error naming the base ---
check '(try (macroexpand (quote (proxy [Runnable] [] (run [] 1)))) :no-throw (catch Throwable e (if (re-find #"not part of ClojureWasm" (str (ex-message e))) :caught :wrong-msg)))' \
      ':caught' proxy_unregistered_base_throws

echo "OK phase15_proxy_threadlocal"
