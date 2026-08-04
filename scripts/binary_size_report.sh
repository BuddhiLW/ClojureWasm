#!/usr/bin/env bash
# binary_size_report.sh — binary-size measurement + size-claims gate (ADR-0172).
#
# Report mode (default):
#   bash scripts/binary_size_report.sh [BIN]
#     Prints total bytes + the segment/section breakdown for BIN
#     (default zig-out/bin/cljw). With a symbol-bearing binary
#     (-Dprofile=true build), also prints the top code symbols so a
#     size jump localizes to a component (the ADR-0172 method).
#
# Gate mode:
#   bash scripts/binary_size_report.sh --check [BIN]
#     Checks EVERY "<N> MB" figure in every file listed in SIZE_CLAIM_FILES
#     against BIN's measured size. Fails (exit 1) when any of them drifts
#     more than 10%. A figure that is deliberately NOT the shipped size
#     (babashka's binary, the ReleaseSmall floor, a historical row) must
#     carry an inline `<!--size:other-->` marker on the same line — so the
#     exemption is explicit and greppable, never silent.
#     Wired into test/run_all.sh as the `size_claims` step (full gate;
#     runs right after build_cljw so the binary is fresh).
#
#     History: the check originally read ONLY README.md's first MB figure.
#     The 2026-08-04 audit found that docs/landscape.md ("~3 MB", 2.4x
#     under) and bench/RELEASE_METRICS.md (a table saying 6.97 MB with
#     prose two paragraphs below still claiming 3.24 MB) had both rotted
#     precisely because nothing checked them — the same shape as zwasm's
#     2026-08-03 `ungated-negative-doc-claim-rotted-into-a-lie` lesson.
#     Every public size claim is gated now.
#
# Reference platform for ADR-0172 numbers: macOS arm64, ReleaseSafe,
# -Dwasm, stripped (= the brew artifact config). MB here is decimal
# (10^6 bytes), matching what brew/GitHub display to users.
set -euo pipefail
cd "$(dirname "$0")/.."

MODE=report
if [[ "${1:-}" == "--check" ]]; then
    MODE=check
    shift
fi
BIN="${1:-zig-out/bin/cljw}"

# ADR-0172 §2 derived ceiling (per-component budgets sum). Keep in sync with
# the ADR's budget table — a change here REQUIRES an ADR-0172 Revision
# history entry (the budget moves consciously, never to silence this check).
BUDGET_CEILING_BYTES=8800000

if [[ ! -f "$BIN" ]]; then
    echo "binary_size_report: binary not found: $BIN (build first: zig build -Dwasm -Doptimize=ReleaseSafe)" >&2
    exit 1
fi

if stat -f%z "$BIN" >/dev/null 2>&1; then
    ACTUAL=$(stat -f%z "$BIN")   # macOS
else
    ACTUAL=$(stat -c%s "$BIN")   # Linux
fi
ACTUAL_MB=$(awk "BEGIN{printf \"%.2f\", $ACTUAL/1000000}")

# Every public document that states the shipped binary's size. Overridable so a
# new doc can be added without editing the script body.
SIZE_CLAIM_FILES="${SIZE_CLAIM_FILES:-README.md docs/landscape.md bench/RELEASE_METRICS.md .dev/ROADMAP.md}"

# A line carrying this marker is exempt: the figure on it is deliberately not
# the shipped size (another project's binary, the ReleaseSmall floor, a dated
# historical row). Exemptions are visible in the source and greppable.
SIZE_EXEMPT_MARKER='<!--size:other-->'

if [[ "$MODE" == "check" ]]; then
    if [[ "$ACTUAL" -gt "$BUDGET_CEILING_BYTES" ]]; then
        echo "size_claims: built binary ${ACTUAL_MB} MB (${ACTUAL} B) exceeds the ADR-0172 derived ceiling ($BUDGET_CEILING_BYTES B)." >&2
        echo "  Attribute with 'bash scripts/binary_size_report.sh' (-Dprofile build for symbols), then land a lever" >&2
        echo "  or consciously amend the budget table in .dev/decisions/0172_binary_size_budget_and_ledger.md." >&2
        exit 1
    fi

    checked=0
    exempt=0
    failed=0
    for f in $SIZE_CLAIM_FILES; do
        if [[ ! -f "$f" ]]; then
            echo "size_claims: listed file not found: $f (fix SIZE_CLAIM_FILES in scripts/binary_size_report.sh)" >&2
            exit 1
        fi
        while IFS=: read -r lineno line; do
            [[ -z "$lineno" ]] && continue
            if [[ "$line" == *"$SIZE_EXEMPT_MARKER"* ]]; then
                exempt=$((exempt + 1))
                continue
            fi
            # A line may carry more than one figure; check each.
            while read -r claim; do
                [[ -z "$claim" ]] && continue
                checked=$((checked + 1))
                DRIFT=$(awk "BEGIN{c=$claim*1000000; d=($ACTUAL-c)/c; if(d<0)d=-d; printf \"%.3f\", d}")
                OK=$(awk "BEGIN{print ($DRIFT <= 0.10) ? 1 : 0}")
                if [[ "$OK" != "1" ]]; then
                    failed=$((failed + 1))
                    echo "size_claims: $f:$lineno claims ${claim} MB but the built binary is ${ACTUAL_MB} MB (${ACTUAL} B) — drift >10%." >&2
                    echo "  → $(printf '%s' "$line" | sed 's/^[[:space:]]*//' | cut -c1-100)" >&2
                fi
            done < <(printf '%s\n' "$line" | grep -oE '[0-9]+(\.[0-9]+)? ?MB' | grep -oE '[0-9]+(\.[0-9]+)?')
        done < <(grep -nE '[0-9]+(\.[0-9]+)? ?MB' "$f" || true)
    done

    if [[ "$checked" -eq 0 ]]; then
        echo "size_claims: no gated '<N> MB' size claim found in: $SIZE_CLAIM_FILES" >&2
        echo "  At least README.md must state the shipped size (ADR-0172). Did every claim get an exemption marker?" >&2
        exit 1
    fi
    if [[ "$failed" -gt 0 ]]; then
        echo "  Update the figure (and CHANGELOG on release) per ADR-0172, or mark the line $SIZE_EXEMPT_MARKER" >&2
        echo "  if it deliberately reports something other than the shipped binary. Do not let a claim rot." >&2
        exit 1
    fi
    echo "    size_claims: ${checked} claim(s) across $(echo "$SIZE_CLAIM_FILES" | wc -w | tr -d ' ') file(s) match ${ACTUAL_MB} MB (${ACTUAL} B) within 10%; ${exempt} line(s) exempt"
    exit 0
fi

echo "== $BIN: ${ACTUAL} bytes (${ACTUAL_MB} MB decimal)"
if command -v size >/dev/null 2>&1; then
    if size -m "$BIN" >/dev/null 2>&1; then
        size -m "$BIN" | grep -E "Segment|Section|total" | grep -v PAGEZERO
    else
        size -A "$BIN" | head -25
    fi
fi

# Symbol attribution (only meaningful on a -Dprofile=true build; a stripped
# release binary has no symbols and this section prints nothing).
if nm -n "$BIN" 2>/dev/null | grep -qi " t "; then
    echo "== top 20 code symbols (build with -Dprofile=true for full attribution)"
    nm -n "$BIN" 2>/dev/null | grep -i " t " | python3 -c '
import sys
syms = []
for line in sys.stdin:
    p = line.split()
    if len(p) >= 3:
        syms.append((int(p[0], 16), p[2]))
syms.sort()
sized = []
for i, (addr, name) in enumerate(syms[:-1]):
    sz = syms[i+1][0] - addr
    if 0 < sz < 10_000_000:
        sized.append((sz, name))
for sz, name in sorted(sized, reverse=True)[:20]:
    print(f"{sz/1024:9.1f} KB  {name[:100]}")
'
fi
