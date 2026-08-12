#!/usr/bin/env bash
# test/golden/run.sh — Layer 6 (Golden snapshot), opened per ADR-0186.
#
# A golden case is a WHOLE PROGRAM plus everything the process produced for it:
# stdout, stderr and exit code, in one file. That is the difference from Layer 2
# (e2e), which asserts a chosen substring of a chosen stream: an e2e case can
# only fail for the thing its author thought to assert, while a snapshot fails
# for any change in what the user sees — a reworded error, a dropped newline, a
# value that starts printing its metadata, a warning that appears on stderr.
#
# That sensitivity is the point and also the cost: a snapshot suite that is
# tedious to update gets updated carelessly. So `--update` regenerates, and the
# diff it produces is the review surface. A reviewer reads the diff, not the
# file.
#
# Determinism is enforced by NORMALISATION, not by hoping: the repo path, hex
# addresses, pids, durations and the version string are rewritten to fixed
# tokens before comparison (see normalise()). A case that still varies run to
# run does not belong in this layer.
#
# Usage:
#   bash test/golden/run.sh                 # verify every case
#   bash test/golden/run.sh --update        # regenerate every .expected
#   bash test/golden/run.sh --only printer  # substring-filter case names
#   CLJW_SKIP_BUILD=1 bash test/golden/run.sh
#
# Adding a case: drop `cases/<name>.clj` in, run with --update, READ the
# generated `.expected`, commit both. A snapshot committed without being read
# is a record of a bug as readily as of a behaviour.
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT=$(pwd)
# CLJW_BIN lets a caller point the suite at a binary built elsewhere — a clean
# git worktree, a downloaded release artifact, a mutant build. Without it the
# suite tests this checkout, which is what the gate wants.
BIN="${CLJW_BIN:-$ROOT/zig-out/bin/cljw}"
CASE_DIR="$ROOT/test/golden/cases"

UPDATE=0
ONLY=""
while [ $# -gt 0 ]; do
    case "$1" in
        --update) UPDATE=1 ;;
        --only) ONLY="$2"; shift ;;
        *) echo "unknown flag: $1" >&2; exit 2 ;;
    esac
    shift
done

[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
[ -x "$BIN" ] || { echo "golden: no binary at $BIN" >&2; exit 1; }

# Rewrite everything that legitimately differs between two runs of the same
# build, and between two machines. Anything not rewritten here is a promise
# that it is stable.
normalise() {
    sed -e "s|$ROOT|<ROOT>|g" \
        -e 's|0x[0-9a-f]\{4,\}|0xADDR|g' \
        -e 's|ClojureWasm v[0-9][0-9.]*|ClojureWasm v<VERSION>|g' \
        -e 's|[0-9]\{1,\}\.[0-9]\{1,\}\(ms\|s\|us\|µs\)|<TIME>|g' \
        -e 's|pid [0-9]\{1,\}|pid <PID>|g' \
        -e 's|/tmp/[A-Za-z0-9_.-]\{6,\}|<TMP>|g'
}

# One case = one file. The envelope is part of the snapshot so a stream moving
# (a message migrating from stdout to stderr) is itself a diff.
capture() {
    local clj="$1" out err rc
    out=$("$BIN" "$clj" 2>/tmp/golden_err.$$ ) && rc=0 || rc=$?
    err=$(cat /tmp/golden_err.$$); rm -f /tmp/golden_err.$$
    {
        echo "--- exit ---"
        echo "$rc"
        echo "--- stdout ---"
        printf '%s\n' "$out"
        echo "--- stderr ---"
        printf '%s\n' "$err"
    } | normalise
}

pass=0; fail=0; updated=0
failed_names=""

for clj in "$CASE_DIR"/*.clj; do
    name=$(basename "$clj" .clj)
    [ -z "$ONLY" ] || case "$name" in *"$ONLY"*) ;; *) continue ;; esac
    expected="$CASE_DIR/$name.expected"
    actual=$(capture "$clj")

    if [ "$UPDATE" = 1 ]; then
        if [ -f "$expected" ] && [ "$actual" = "$(cat "$expected")" ]; then
            pass=$((pass + 1))
        else
            printf '%s\n' "$actual" > "$expected"
            updated=$((updated + 1))
            echo "UPDATED $name"
        fi
        continue
    fi

    if [ ! -f "$expected" ]; then
        echo "FAIL $name — no snapshot; run with --update and read the result" >&2
        fail=$((fail + 1)); failed_names="$failed_names $name"
    elif [ "$actual" = "$(cat "$expected")" ]; then
        pass=$((pass + 1))
    else
        echo "FAIL $name" >&2
        diff -u "$expected" <(printf '%s\n' "$actual") | head -40 >&2 || true
        fail=$((fail + 1)); failed_names="$failed_names $name"
    fi
done

if [ "$UPDATE" = 1 ]; then
    echo "golden: $updated updated, $pass unchanged"
    exit 0
fi

echo "golden: $pass passed, $fail failed"
[ "$fail" = 0 ] || { echo "golden: failing cases:$failed_names" >&2; exit 1; }
