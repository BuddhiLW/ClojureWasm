#!/usr/bin/env python3
"""Layer 8 (Mutation) mutant enumerator and applier — ADR-0186.

A mutant is one textual change to one Zig source line that alters BEHAVIOUR
while keeping the file plausible: a comparison flipped, an arithmetic operator
swapped, a boolean connective changed, a small constant nudged, a branch forced.
If the suite still passes with the change in place, no test constrains that line.

Two subcommands:

    mutate.py list <file.zig> [--seed N] [--limit K]
        Print one JSON object per candidate mutant. Deterministic for a seed.

    mutate.py apply <file.zig> <mutant-id>
        Rewrite the file in place with that mutant applied. Prints the diff line.

The enumerator never touches comments, doc comments, string and character
literals, `@import` lines, or `test "..."` blocks. The applier NEVER writes
outside the file it is given, and `run.sh` only ever gives it paths inside a
throwaway git worktree.
"""

import argparse
import hashlib
import json
import random
import re
import sys

# (name, pattern, replacement) — each is a behaviour change, not a refactor.
# Every binary-operator rule matches only the SPACED form (`a * b`, never
# `*const T` or `ptr.*`).
OPERATORS = [
    ("cmp_lt_to_le", r"(?<=[\w\)\]]) < (?=[\w\(@])", " <= "),
    ("cmp_gt_to_ge", r"(?<=[\w\)\]]) > (?=[\w\(@])", " >= "),
    ("cmp_le_to_lt", r"(?<=[\w\)\]]) <= (?=[\w\(@])", " < "),
    ("cmp_ge_to_gt", r"(?<=[\w\)\]]) >= (?=[\w\(@])", " > "),
    ("cmp_eq_to_ne", r"(?<=[\w\)\]]) == (?=[\w\(@.])", " != "),
    ("cmp_ne_to_eq", r"(?<=[\w\)\]]) != (?=[\w\(@.])", " == "),
    ("arith_add_to_sub", r"(?<=[\w\)\]]) \+ (?=[\w\(@])", " - "),
    ("arith_sub_to_add", r"(?<=[\w\)\]]) - (?=[\w\(@])", " + "),
    ("arith_mul_to_div", r"(?<=[\w\)\]]) \* (?=[\w\(@])", " / "),
    ("bool_and_to_or", r"(?<=[\w\)\]]) and (?=[\w\(@!])", " or "),
    ("bool_or_to_and", r"(?<=[\w\)\]]) or (?=[\w\(@!])", " and "),
    # Constants only where they are being COMPARED or COMBINED.
    ("const_bump_after_cmp", r"(?<=[<>!=]= )([0-9]+)(?![\w.])", None),
    ("const_bump_in_arith", r"(?<=[+\-*/] )([0-9]+)(?![\w.])", None),
    ("branch_force_true", r"\bif \(([^()]{1,60})\)", "if (true)"),
]

# Rules whose replacement is computed from the match rather than fixed.
def _replacement(op_name: str, match: "re.Match", fixed):
    if fixed is not None:
        return fixed
    n = int(match.group(1))
    return match.group(0).replace(str(n), str(n + 1), 1)

SKIP_LINE = re.compile(
    r"""^\s*(
          //                    # comment or doc comment
        | \#                    # (defensive)
        | const\s+\w+\s*=\s*@import
        | test\s+"              # a test block header
        | pub\s+const\s+\w+\s*=\s*@import
    )""",
    re.VERBOSE,
)


def mask_literals(line: str) -> str:
    """Replace string/char literal CONTENT with placeholders of equal length, so
    offsets stay valid while the matcher cannot see inside a literal."""
    out = list(line)
    i, n = 0, len(line)
    while i < n:
        ch = line[i]
        if ch in ('"', "'"):
            quote = ch
            j = i + 1
            while j < n:
                if line[j] == "\\":
                    j += 2
                    continue
                if line[j] == quote:
                    break
                j += 1
            for k in range(i + 1, min(j, n)):
                out[k] = "_"
            i = j + 1
            continue
        if ch == "/" and i + 1 < n and line[i + 1] == "/":
            for k in range(i, n):
                out[k] = "_"
            break
        i += 1
    return "".join(out)


def in_test_block(lines, idx: int) -> bool:
    """True when the line sits inside a `test "..." { ... }` block. Tracks depth
    from the nearest preceding top-level `test` header."""
    depth = 0
    for i in range(idx, -1, -1):
        line = mask_literals(lines[i])
        if i != idx:
            depth += line.count("}") - line.count("{")
        if re.match(r'^test\s+["{]', lines[i]):
            return depth <= 0
        if re.match(r"^(pub\s+)?fn |^pub const |^const .*= struct", lines[i]) and depth <= 0:
            return False
    return False


def enumerate_mutants(path: str):
    with open(path, "r", encoding="utf-8") as fh:
        lines = fh.read().split("\n")

    mutants = []
    for idx, raw in enumerate(lines):
        if not raw.strip() or SKIP_LINE.match(raw):
            continue
        if in_test_block(lines, idx):
            continue
        masked = mask_literals(raw)
        for op_name, pattern, repl in OPERATORS:
            for m in re.finditer(pattern, masked):
                start, end = m.span()
                mutated = raw[:start] + _replacement(op_name, m, repl) + raw[end:]
                if mutated == raw:
                    continue
                ident = hashlib.sha1(
                    f"{path}:{idx}:{start}:{op_name}".encode()
                ).hexdigest()[:12]
                mutants.append(
                    {
                        "id": ident,
                        "file": path,
                        "line": idx + 1,
                        "col": start + 1,
                        "op": op_name,
                        "before": raw.strip()[:120],
                        "after": mutated.strip()[:120],
                    }
                )
    return mutants


def apply_mutant(path: str, mutant_id: str) -> dict:
    mutants = {m["id"]: m for m in enumerate_mutants(path)}
    if mutant_id not in mutants:
        raise SystemExit(f"no mutant {mutant_id} in {path}")
    m = mutants[mutant_id]

    with open(path, "r", encoding="utf-8") as fh:
        lines = fh.read().split("\n")

    idx = m["line"] - 1
    raw = lines[idx]
    for op_name, pattern, repl in OPERATORS:
        if op_name != m["op"]:
            continue
        masked = mask_literals(raw)
        for hit in re.finditer(pattern, masked):
            if hit.start() == m["col"] - 1:
                lines[idx] = raw[: hit.start()] + _replacement(op_name, hit, repl) + raw[hit.end() :]
                with open(path, "w", encoding="utf-8") as fh:
                    fh.write("\n".join(lines))
                return m
    raise SystemExit(f"mutant {mutant_id} no longer applies to {path} (file changed?)")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)

    lst = sub.add_parser("list")
    lst.add_argument("file")
    lst.add_argument("--seed", type=int, default=0)
    lst.add_argument("--limit", type=int, default=0)

    app = sub.add_parser("apply")
    app.add_argument("file")
    app.add_argument("mutant_id")

    args = ap.parse_args()

    if args.cmd == "list":
        mutants = enumerate_mutants(args.file)
        if args.limit and len(mutants) > args.limit:
            random.Random(args.seed).shuffle(mutants)
            mutants = mutants[: args.limit]
            mutants.sort(key=lambda m: (m["line"], m["col"]))
        for m in mutants:
            print(json.dumps(m))
        return 0

    m = apply_mutant(args.file, args.mutant_id)
    print(json.dumps(m))
    return 0


if __name__ == "__main__":
    sys.exit(main())
