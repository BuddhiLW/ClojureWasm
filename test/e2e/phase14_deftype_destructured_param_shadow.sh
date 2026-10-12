#!/usr/bin/env bash
# test/e2e/phase14_deftype_destructured_param_shadow.sh
#
# A defrecord / deftype method parameter that DESTRUCTURES to a name equal to
# a field must shadow the field, as on the JVM. The lowering wraps each method
# body in a `let*` that binds the fields; a field bound by the parameter
# pattern (`{:keys [a]}`, `[a b]`, `{a :k}`, `:as a`) must be left out of that
# `let*`, or the field silently wins over the argument (found via desargues'
# RK4 `Pendulum/derivatives [this {:keys [theta omega]}]`).

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() {
    local name="$1"; local got="$2"; local want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}
run() { "$BIN" - 2>&1 | tail -n 1; }

got=$(run <<'EOF'
(defprotocol P (f [this m]) (g [this x]) (h [this m]))
(defrecord R [a]
  P
  (f [_ {:keys [a]}] a)
  (g [_ a] a)
  (h [_ m] (let [{:keys [a]} m] a)))
(let [r (->R :field)]
  (prn [(f r {:a :param}) (g r :param) (h r {:a :param})]))
EOF
)
assert_eq 'defrecord_keys_param_shadows_field' "$got" '[:param :param :param]'

got=$(run <<'EOF'
(defprotocol Q (q1 [this v]) (q2 [this m]) (q3 [this m]) (q4 [this m]))
(defrecord S [a b]
  Q
  (q1 [_ [a]] [a b])
  (q2 [_ {a :x}] [a b])
  (q3 [_ {:as a}] [a b])
  (q4 [_ {:keys [c] :or {a 9}}] [a b c]))
(let [s (->S :fa :fb)]
  (prn [(q1 s [:p]) (q2 s {:x :p}) (q3 s {:k 1}) (q4 s {:c 3})]))
EOF
)
assert_eq 'defrecord_vector_map_as_or_patterns' "$got" '[[:p :fb] [:p :fb] [{:k 1} :fb] [:fa :fb 3]]'

got=$(run <<'EOF'
(defprotocol D (step [this state dt]))
(deftype Pend [theta omega]
  D
  (step [_ {:keys [theta omega]} dt] [(+ theta dt) (+ omega dt)]))
(prn (step (->Pend 100 200) {:theta 1 :omega 2} 10))
EOF
)
assert_eq 'deftype_keys_param_shadows_field' "$got" '[11 12]'

echo "phase14_deftype_destructured_param_shadow: all passed"
