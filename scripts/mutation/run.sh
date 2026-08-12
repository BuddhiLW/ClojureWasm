#!/usr/bin/env bash
# scripts/mutation/run.sh — Layer 8 (Mutation) sweep. ADR-0186.
#
# Changes one line of one source file, rebuilds, runs the unit suite, and records
# whether anything failed. A mutant the suite still passes is a SURVIVOR: that
# line's behaviour is unconstrained by any test, and the survivor names it
# exactly — file, line, and the change nobody noticed.
#
# This is a measurement, not a gate. It runs on demand and on a schedule; a
# survivor is a work-list entry, not a commit to block. Cost is one rebuild per
# mutant, so `--budget` is the parameter that matters.
#
# ISOLATION (the rule that makes this safe to run): the sweep NEVER touches your
# checkout. It creates a detached git worktree at a chosen revision, mutates
# files there, and removes it at the end. Mutating the working tree would put
# uncommitted work one `git checkout --` away from deletion, and an interrupted
# run would leave a mutant behind that reads exactly like a deliberate edit.
#
# Usage:
#   bash scripts/mutation/run.sh --targets src/runtime/collection/set.zig
#   bash scripts/mutation/run.sh --targets a.zig,b.zig --budget 20 --seed 7
#   bash scripts/mutation/run.sh --targets-from .dev/mutation_targets.txt --rev v1.10.1
#   bash scripts/mutation/run.sh --targets v.zig --ids 1a2b3c,4d5e6f   # re-run named mutants
#
# `--ids` is the loop that makes a survivor actionable: a survivor names a line,
# you write the test that should have constrained it, then you re-run THAT
# mutant to see it die. Without it you are re-sampling and hoping.
#
# Output: a JSONL log plus a markdown summary under .dev/mutation/ (gitignored
# by default — the REPORT is the artifact worth committing, not the log).
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO_ROOT=$(pwd)

TARGETS=""
TARGETS_FILE=""
BUDGET=15
SEED=0
IDS=""
REV="HEAD"
OUT_DIR="$REPO_ROOT/.dev/mutation"
EQUIV_FILE="$REPO_ROOT/.dev/mutation_equivalent.jsonl"
BUILD_ARGS="-Dwasm -Doptimize=Debug"
# A mutant can hang (a loop bound flipped). Time out generously enough that a
# slow machine is not mistaken for a hang, and treat a timeout as KILLED: a
# change that makes the suite never finish is a change the suite detected.
PER_MUTANT_TIMEOUT=900

while [ $# -gt 0 ]; do
    case "$1" in
        --targets) TARGETS="$2"; shift ;;
        --targets-from) TARGETS_FILE="$2"; shift ;;
        --budget) BUDGET="$2"; shift ;;
        --ids) IDS="$2"; shift ;;
        --seed) SEED="$2"; shift ;;
        --rev) REV="$2"; shift ;;
        --out) OUT_DIR="$2"; shift ;;
        --equivalent) EQUIV_FILE="$2"; shift ;;
        --build-args) BUILD_ARGS="$2"; shift ;;
        --timeout) PER_MUTANT_TIMEOUT="$2"; shift ;;
        *) echo "unknown flag: $1" >&2; exit 2 ;;
    esac
    shift
done

if [ -n "$TARGETS_FILE" ]; then
    TARGETS=$(grep -v '^\s*#' "$TARGETS_FILE" | grep -v '^\s*$' | paste -sd, -)
fi
[ -n "$TARGETS" ] || { echo "nothing to mutate: pass --targets or --targets-from" >&2; exit 2; }

# Portable bounded run (check_portable_timeout.sh: no bare `timeout`).
run_bounded() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"
    else "$@"; fi
}

WORKTREE=$(mktemp -d "${TMPDIR:-/tmp}/cljw-mutation-XXXXXX")
case "$WORKTREE" in
    "$REPO_ROOT"|"$REPO_ROOT"/*)
        echo "refusing to mutate inside the repository: $WORKTREE" >&2; exit 1 ;;
esac

cleanup() {
    cd "$REPO_ROOT"
    git worktree remove --force "$WORKTREE" >/dev/null 2>&1 || rm -rf "$WORKTREE"
}
trap cleanup EXIT

echo "mutation: worktree $WORKTREE at $REV"
git worktree add --detach "$WORKTREE" "$REV" >/dev/null

mkdir -p "$OUT_DIR"
STAMP=$(git rev-parse --short "$REV")
LOG="$OUT_DIR/mutants-$STAMP-seed$SEED.jsonl"
REPORT="$OUT_DIR/report-$STAMP-seed$SEED.md"
: > "$LOG"

# --- baseline -------------------------------------------------------------
# Without this, a tree that is already red reports every mutant as killed and
# the sweep produces a perfect score for a broken suite.
echo "mutation: baseline build + test (this must pass) …"
if ! ( cd "$WORKTREE" && run_bounded "$PER_MUTANT_TIMEOUT" zig build test $BUILD_ARGS ) >"$OUT_DIR/baseline.log" 2>&1; then
    echo "mutation: BASELINE FAILED at $REV — fix the suite before measuring it." >&2
    tail -20 "$OUT_DIR/baseline.log" >&2
    exit 1
fi
echo "mutation: baseline green"

# --- enumerate + sample ---------------------------------------------------
ALL_MUTANTS="$OUT_DIR/candidates-$STAMP.jsonl"
: > "$ALL_MUTANTS"
IFS=',' read -ra TARGET_LIST <<< "$TARGETS"
for t in "${TARGET_LIST[@]}"; do
    [ -f "$WORKTREE/$t" ] || { echo "mutation: no such target $t" >&2; exit 2; }
    ( cd "$WORKTREE" && python3 "$REPO_ROOT/scripts/mutation/mutate.py" list "$t" ) >> "$ALL_MUTANTS"
done

TOTAL=$(wc -l < "$ALL_MUTANTS" | tr -d ' ')
SAMPLE="$OUT_DIR/sample-$STAMP-seed$SEED.jsonl"
python3 - "$ALL_MUTANTS" "$SAMPLE" "$BUDGET" "$SEED" "$IDS" <<'PY'
import json, random, sys
src, dst, budget, seed = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
ids = [i for i in sys.argv[5].split(",") if i] if len(sys.argv) > 5 else []
rows = [json.loads(l) for l in open(src) if l.strip()]
if ids:
    by_id = {r["id"]: r for r in rows}
    missing = [i for i in ids if i not in by_id]
    if missing:
        # A named mutant that no longer exists means the line moved or changed.
        # Silently running the rest would report a kill that never happened.
        raise SystemExit("mutants no longer present (did the file change?): " + ", ".join(missing))
    rows = [by_id[i] for i in ids]
    budget = 0
if budget and len(rows) > budget:
    # Sample across the whole candidate set, not the head of it — a truncated
    # list only ever measures the top of each file.
    rows = random.Random(seed).sample(rows, budget)
rows.sort(key=lambda r: (r["file"], r["line"], r["col"]))
with open(dst, "w") as fh:
    for r in rows:
        fh.write(json.dumps(r) + "\n")
print(f"mutation: {len(rows)} of {len(open(src).readlines())} candidates selected")
PY

# --- run ------------------------------------------------------------------
killed=0; survived=0; unviable=0; n=0
SELECTED=$(wc -l < "$SAMPLE" | tr -d ' ')

while IFS= read -r row; do
    n=$((n + 1))
    id=$(printf '%s' "$row" | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')
    file=$(printf '%s' "$row" | python3 -c 'import json,sys;print(json.load(sys.stdin)["file"])')
    op=$(printf '%s' "$row" | python3 -c 'import json,sys;print(json.load(sys.stdin)["op"])')
    line=$(printf '%s' "$row" | python3 -c 'import json,sys;print(json.load(sys.stdin)["line"])')

    ( cd "$WORKTREE" && git checkout -- "$file" )
    ( cd "$WORKTREE" && python3 "$REPO_ROOT/scripts/mutation/mutate.py" apply "$file" "$id" >/dev/null )

    set +e
    ( cd "$WORKTREE" && run_bounded "$PER_MUTANT_TIMEOUT" zig build test $BUILD_ARGS ) \
        >"$OUT_DIR/mutant-$id.log" 2>&1
    rc=$?
    set -e

    if [ $rc -eq 0 ]; then
        verdict=survived; survived=$((survived + 1))
    elif grep -qE "^(src/|/).*error: " "$OUT_DIR/mutant-$id.log" && \
         ! grep -q "test failure" "$OUT_DIR/mutant-$id.log"; then
        # Did not compile: says nothing about the suite.
        verdict=unviable; unviable=$((unviable + 1))
        rm -f "$OUT_DIR/mutant-$id.log"
    else
        verdict=killed; killed=$((killed + 1))
        rm -f "$OUT_DIR/mutant-$id.log"
    fi

    printf '%s\n' "$row" | python3 -c "
import json, sys
row = json.load(sys.stdin)
row['verdict'] = '$verdict'
print(json.dumps(row))
" >> "$LOG"

    printf '  [%d/%d] %-9s %s:%s %s\n' "$n" "$SELECTED" "$verdict" "$file" "$line" "$op"
done < "$SAMPLE"

( cd "$WORKTREE" && git checkout -- . )

# --- report ---------------------------------------------------------------
# Survivors are reclassified against the equivalence register: a mutant listed
# there has a written proof that no input can observe it, so it is excluded
# from the score rather than counted as a missing test.
set +e
python3 "$REPO_ROOT/scripts/mutation/report.py" \
    --log "$LOG" --report "$REPORT" --stamp "$STAMP" --seed "$SEED" \
    --total "$TOTAL" --candidates "$ALL_MUTANTS" --equivalent "$EQUIV_FILE"
report_rc=$?
set -e

echo "mutation: raw verdicts killed=$killed survived=$survived unviable=$unviable (log: $LOG)"
exit $report_rc
