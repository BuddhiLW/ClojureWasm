#!/usr/bin/env bash
# check_gate_parity.sh — the local full gate and the CI full gate must run the
# SAME configuration.
#
#   bash scripts/check_gate_parity.sh
#
# `scripts/ci_gate.sh` says, in its own header, "FULL gate == the LOCAL full
# gate … (test/run_all.sh --serial-e2e)". That sentence was false for months:
# `ci_gate.sh` passed `--serial-e2e`, `run_gate.sh` passed nothing, and
# `run_all.sh` defaults to `PARALLEL_E2E=1`. So "the local full gate is green"
# and "CI is green" were statements about two different test runs.
#
# It is not a theoretical gap. The parallel path captures each job's output to a
# file; the serial path pipes it. An e2e whose producer took SIGPIPE from a
# `head -N` therefore died silently under serial and passed under parallel —
# green on every local full gate, red on every push (2026-08-04).
#
# Two launchers can stay, but their agreement has to be executed rather than
# asserted in a comment. That is the whole content of this check.
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0
note() { echo "check_gate_parity: $1" >&2; fail=1; }

# The mode each launcher hands to run_all.sh for a FULL (non-smoke) run.
ci_line="$(grep -nE '^\s*bash test/run_all.sh' scripts/ci_gate.sh | grep -v -- '--smoke' || true)"
[[ -n "$ci_line" ]] || note "scripts/ci_gate.sh has no full-gate 'bash test/run_all.sh' line — did it change shape?"
printf '%s' "$ci_line" | grep -q -- '--serial-e2e' \
    || note "scripts/ci_gate.sh's full gate no longer passes --serial-e2e: $ci_line"

grep -q -- 'MODE=(--serial-e2e)' scripts/run_gate.sh \
    || note "scripts/run_gate.sh no longer defaults to --serial-e2e, so the local full gate would validate a different configuration from CI."

# `run_all.sh` still has to HAVE the flag for either to mean anything.
grep -q -- '--serial-e2e)' test/run_all.sh \
    || note "test/run_all.sh no longer accepts --serial-e2e; both launchers are passing a flag it ignores."

if [[ "$fail" -ne 0 ]]; then
    echo "  A local 'full gate green' must mean the same run CI will do. Fix the launcher, or" >&2
    echo "  change BOTH and update ci_gate.sh's header claim in the same commit." >&2
    exit 1
fi
echo "    gate_parity: run_gate.sh and ci_gate.sh both run the full gate with --serial-e2e"
