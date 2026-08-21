#!/usr/bin/env bash
# scripts/check_corpus_regression.sh — replay the clj-diff corpus through cljw.
#
# Every `test/diff/clj_corpus/*.txt` (general behaviour) and
# `test/diff/class_corpus/*.txt` (F-014/ADR-0136 per-class Java completeness)
# holds golden `expr` / `;;=> <output>` pairs captured by
# `scripts/clj_diff_sweep.sh --corpus` / `--class-corpus` at the moment cljw
# matched the clj oracle. This check re-runs each `expr` through cljw ONLY
# (no clj, no network) and fails if the output drifts from the stored
# `;;=>`. That makes a discharged "X/Y landed" debt claim mechanically
# re-checkable (anti D-177 false-positive-discharge), and catches plain
# regressions in landed behaviour. For class_corpus it also locks per-class
# Java surface completeness: a method clj answers and cljw stops answering
# (or drifts) fails the gate.
#
# Usage: bash scripts/check_corpus_regression.sh        # all corpora
#        bash scripts/check_corpus_regression.sh seqfns # one corpus stem
#        bash scripts/check_corpus_regression.sh String # one class corpus stem
#        CORPUS_JOBS=1 bash scripts/check_corpus_regression.sh   # force serial
#
# Exit 0 = all golden outputs reproduced; 1 = at least one drift / error.
#
# CONCURRENCY — across FILES, never across expressions. Measured 2026-08-19:
# 252 corpus files hold 4384 expressions, and every one of them spawns its own
# `cljw`. That IS the step's cost (4384 × ~40 ms ≈ 175 s; the step measured
# 147 s on the Linux CI leg and 137 s locally). Nothing else happens here.
#
# Each expression still gets its own process, so isolation is byte-for-byte
# what it was. That is deliberate and it is the expensive choice: batching a
# whole file into ONE `cljw` would cut the step to a few seconds, but the
# goldens would then share a runtime, and a stray `def` or atom mutation could
# leak from one expression into the next. A leak that turned a DRIFT into a
# PASS is a gate that has quietly stopped checking — strictly worse than a slow
# gate. Files, by contrast, are independent by construction (each is its own
# golden set), so running N at once changes nothing observable.
#
# Workers write to their own temp file and the driver concatenates in the
# original file order: a DRIFT report is multi-line and larger than PIPE_BUF,
# so concurrent writers to one stream would interleave *within* a report. It
# also keeps the log byte-identical between runs, which is most of what makes
# CI output worth reading.

set -uo pipefail
cd "$(dirname "$0")/.."

BIN="zig-out/bin/cljw"
# Build unless told not to. A worker (CORPUS_ONE=1) is re-entering this same
# script, so it must NOT build: the driver already did, and 252 workers each
# running even a no-op `zig build` would cost more than the whole step.
[ -n "${CLJW_SKIP_BUILD:-}${CORPUS_ONE:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
# Portable bounded run: GNU `timeout`, else macOS coreutils `gtimeout`, else
# unbounded. The corpus exprs are all finite, so the fallback is safe — the
# bound only defends against an accidental infinite-seq regression. (Written as
# a function, not an array, to stay bash-3.2-safe under `set -u`.)
run_bounded() {
    if command -v timeout >/dev/null 2>&1; then timeout 20 "$@"
    elif command -v gtimeout >/dev/null 2>&1; then gtimeout 20 "$@"
    else "$@"; fi
}

# Both the general behaviour corpus and the per-class Java-completeness
# corpus (F-014/ADR-0136) are gated. A given stem is looked up in both dirs.
dirs=("test/diff/clj_corpus" "test/diff/class_corpus")

files=()
if [ $# -gt 0 ]; then
    for d in "${dirs[@]}"; do files+=("$d/$1.txt"); done
else
    for d in "${dirs[@]}"; do
        [ -d "$d" ] && files+=("$d"/*.txt)
    done
fi

if [ "${#files[@]}" -eq 0 ]; then
    echo "no corpus directories (${dirs[*]}) — nothing to check"
    exit 0
fi

# Replay one corpus file. Prints DRIFT reports, then one machine-readable
# tally line the driver sums. Factored out of the old inline loop unchanged.
replay_file() {
    local f="$1"
    local total=0 fails=0 expr="" line want reqs ns got
    [ -f "$f" ] || { printf '__TALLY\t0\t0\n'; return 0; }
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ''|';;'*'=> '*)
                if [ -n "$expr" ] && [ "${line#';;=> '}" != "$line" ]; then
                    want="${line#';;=> '}"
                    # ADR-0163 D-516: corpus exprs are bare value-forms; a qualified
                    # clojure.*/cljw.* var of a now-LAZY ns needs a require first (clj-parity,
                    # like clj). Auto-require each such ns ahead of the prn (an EAGER ns →
                    # idempotent no-op; Java FQCNs like java.util.UUID/ are excluded — they
                    # need no require). Mirrors clj_diff_sweep.sh's batch-prelude.
                    reqs=""
                    for ns in $(printf '%s' "$expr" | grep -oE '(clojure|cljw)\.[a-zA-Z0-9._-]+/' | sed 's:/$::' | sort -u); do
                        # try/catch so a NON-requireable prefix (a JVM-class static like
                        # clojure.lang.PersistentQueue/EMPTY, which cljw resolves natively
                        # and must NOT `require`) is swallowed instead of aborting the expr.
                        reqs="$reqs(try (require '$ns) (catch Throwable _ nil))"
                    done
                    # Run via stdin (`cljw -`), NOT `-e`: `-e` echoes EVERY top-level form's
                    # value, so a prepended `(require …)` would print `nil` as the first line
                    # and `head -1` would grab it instead of the prn output. Stdin prints only
                    # explicit output (the prn). (memory: cljw_e_prints_each_form.)
                    got="$(printf '%s(prn %s)' "$reqs" "$expr" | run_bounded "$BIN" - 2>&1 | sed -n 1p)"
                    total=$((total + 1))
                    if [ "$got" != "$want" ]; then
                        printf 'DRIFT [%s] %s\n   want=[%s]\n    got=[%s]\n' "$(basename "$f" .txt)" "$expr" "$want" "$got"
                        fails=$((fails + 1))
                    fi
                    expr=""
                fi
                ;;
            ';'*) : ;;            # other comment line — ignore
            *) expr="$line" ;;    # an expression line
        esac
    done < "$f"
    printf '__TALLY\t%s\t%s\n' "$total" "$fails"
}

# Worker mode: one file, output to stdout (the driver redirects it).
if [ "${CORPUS_ONE:-}" = "1" ]; then
    replay_file "$1"
    exit 0
fi

# --- driver ----------------------------------------------------------------
# Default job count: cores, capped at 8 — a 2-vCPU runner must not spawn 8.
if [ -n "${CORPUS_JOBS:-}" ]; then
    JOBS="$CORPUS_JOBS"
else
    JOBS=$( (nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2) )
    [ "$JOBS" -gt 8 ] && JOBS=8
fi

total=0
fails=0

if [ "$JOBS" -le 1 ]; then
    for f in "${files[@]}"; do
        while IFS= read -r out; do
            case "$out" in
                __TALLY*) total=$((total + $(printf '%s' "$out" | cut -f2)))
                          fails=$((fails + $(printf '%s' "$out" | cut -f3))) ;;
                *) printf '%s\n' "$out" ;;
            esac
        done < <(replay_file "$f")
    done
else
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/corpus_regression.XXXXXX")
    trap 'rm -rf "$tmp"' EXIT INT TERM

    # NUL-delimited through a pipe, not `xargs -a`: BSD/macOS xargs has no -a.
    # Each worker names its own output file after its input path, so the
    # fan-out needs no coordination with the ordered read-back below.
    printf '%s\0' "${files[@]}" \
        | CORPUS_ONE=1 CORPUS_OUT="$tmp" xargs -0 -P "$JOBS" -n 1 \
          bash -c 'out="$CORPUS_OUT/$(printf "%s" "$1" | tr "/" "_")"; bash "$0" "$1" > "$out" 2>&1' \
          "${BASH_SOURCE[0]}"

    for f in "${files[@]}"; do
        out="$tmp/$(printf '%s' "$f" | tr '/' '_')"
        [ -f "$out" ] || continue
        while IFS= read -r line; do
            case "$line" in
                __TALLY*) total=$((total + $(printf '%s' "$line" | cut -f2)))
                          fails=$((fails + $(printf '%s' "$line" | cut -f3))) ;;
                *) printf '%s\n' "$line" ;;
            esac
        done < "$out"
    done
fi

echo "corpus regression: $((total - fails))/$total golden outputs reproduced"
[ "$fails" -eq 0 ]
