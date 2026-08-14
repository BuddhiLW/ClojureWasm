#!/usr/bin/env bash
# test/e2e/future_methods.sh
#
# java.util.concurrent.Future's METHOD NAMES over cljw's native `.future`
# (runtime/java/util/concurrent/Future.zig), plus Future as a reify target
# (host_interface.zig FUTURE).
#
# The point of the surface is that `.get` and `@` cannot disagree: both must
# report the same terminal state for the same future (value, cancelled, thrown).
# The one deliberate difference from cljw's own deref is the timed arity, which
# must THROW TimeoutException rather than return a default — a library catching
# TimeoutException to decide whether to cancel would read a returned default as
# success.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() {
    local name="$1" got="$2" want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}
run() { "$BIN" -e "$1" 2>/dev/null; }

MS='java.util.concurrent.TimeUnit/MILLISECONDS'

# --- .get agrees with deref on a value ---
assert_eq 'get_value'        "$(run '(.get (future (+ 1 2)))')" '3'
assert_eq 'get_matches_deref' "$(run '(let [f (future (* 6 7))] [(.get f) @f])')" '[42 42]'
assert_eq 'get_nil_body'     "$(run '(nil? (.get (future nil)))')" 'true'

# --- .isDone is realized?: true for value, error AND cancellation ---
assert_eq 'isDone_after_value' "$(run '(let [f (future 1)] @f (.isDone f))')" 'true'
assert_eq 'isDone_matches_realized' \
  "$(run '(let [f (future 1)] @f [(.isDone f) (realized? f)])')" '[true true]'
assert_eq 'isDone_after_cancel' \
  "$(run '(let [f (future (Thread/sleep 5000))] (.cancel f true) (.isDone f))')" 'true'

# --- .cancel / .isCancelled agree with future-cancel / future-cancelled? ---
assert_eq 'cancel_pending_wins' \
  "$(run '(let [f (future (Thread/sleep 5000))] [(.cancel f true) (.isCancelled f)])')" '[true true]'
assert_eq 'cancel_twice_second_loses' \
  "$(run '(let [f (future (Thread/sleep 5000))] [(.cancel f true) (.cancel f true)])')" '[true false]'
assert_eq 'cancel_realised_returns_false' \
  "$(run '(let [f (future 1)] @f (.cancel f true))')" 'false'
assert_eq 'isCancelled_false_when_completed' \
  "$(run '(let [f (future 1)] @f [(.isCancelled f) (future-cancelled? f)])')" '[false false]'

# AD-065: the mayInterruptIfRunning flag is accepted and IGNORED, and the
# 1-arity is accepted. On the JVM `(.cancel f false)` would refuse a running
# task; cljw cancels either way.
assert_eq 'cancel_flag_is_ignored_ad065' \
  "$(run '(let [f (future (Thread/sleep 5000))] [(.cancel f false) (.isCancelled f)])')" '[true true]'
assert_eq 'cancel_arity_1_accepted' \
  "$(run '(let [f (future (Thread/sleep 5000))] (.cancel f))')" 'true'

# --- .get on a cancelled future throws CancellationException, as @ does ---
assert_eq 'get_cancelled_throws_cancellation' \
  "$(run '(let [f (future (Thread/sleep 5000))]
             (.cancel f true)
             (try (.get f) :no-throw
               (catch java.util.concurrent.CancellationException _ :cancellation)))')" \
  ':cancellation'

# --- .get on a thrown body re-raises the ORIGINAL error (ADR-0120), as @ does ---
assert_eq 'get_rethrows_original' \
  "$(run '(let [f (future (throw (ex-info "boom" {:a 1})))]
             (try (.get f) :no-throw (catch Exception e (keyword (.getMessage e)))))')" \
  ':boom'

# --- timed .get: value in time, TimeoutException past it ---
assert_eq 'get_timed_returns_value' \
  "$(run "(.get (future (+ 20 22)) 2000 $MS)")" '42'
assert_eq 'get_timed_throws_timeout' \
  "$(run "(let [f (future (Thread/sleep 5000))]
             (try (.get f 50 $MS) :no-throw
               (catch java.util.concurrent.TimeoutException _ :timeout)))")" \
  ':timeout'
# TimeoutException is an Exception, so a broad catch still sees it.
assert_eq 'timeout_is_an_exception' \
  "$(run "(let [f (future (Thread/sleep 5000))]
             (try (.get f 50 $MS) :no-throw (catch Exception _ :caught)))")" \
  ':caught'
# The timed arity must NOT quietly return a default the way cljw's 3-arity
# deref does — that is the whole reason it exists separately.
assert_eq 'timed_deref_still_returns_default' \
  "$(run '(deref (future (Thread/sleep 5000)) 50 :fallback)')" ':fallback'

# --- bad unit is a type error, not a silent success ---
assert_eq 'get_timed_bad_unit' \
  "$(run '(let [f (future 1)] (try (.get f 10 :not-a-unit) :no-throw (catch Exception _ :threw)))')" \
  ':threw'

# --- Future is reify-able: a synthetic already-completed Future ---
# hive-weave.pool returns one of these when the pool is shut down and the work
# ran on the caller thread.
assert_eq 'reify_future_get' \
  "$(run '(let [f (reify java.util.concurrent.Future
                    (get [_] 99)
                    (get [_ _t _u] 99)
                    (isDone [_] true)
                    (isCancelled [_] false)
                    (cancel [_ _] false))]
             [(.get f) (.isDone f) (.isCancelled f) (.cancel f true)])')" \
  '[99 true false false]'
# The bare post-:import spelling must resolve to the same interface.
assert_eq 'reify_future_bare_spelling' \
  "$(run '(let [f (reify Future (get [_] 7) (isDone [_] true) (isCancelled [_] false) (cancel [_ _] false))]
             [(.get f) (.isDone f)])')" \
  '[7 true]'

# --- class identity is unchanged ---
assert_eq 'class_name' "$(run '(= "Future" (str (class (future 1))))')" 'true'

echo "OK test/e2e/future_methods.sh"
