# 0046 — Upstream skip taxonomy + Tier A 100% PASS gate semantics

- **Status**: Accepted
- **Date**: 2026-05-27
- **Author**: Shota Kudo (drafted with Claude autonomous loop)
- **Tags**: F-002, Phase-11, test-corpus, Tier-A, gate

## Context

Phase 11 ports the upstream Clojure test corpus
(`~/Documents/OSS/clojure/test/`) under `test/clj/` and wires
the Tier A 100% PASS gate into `test/run_all.sh`. The gate has
two failure modes the loop must distinguish:

1. **A cw v1 bug** — the ported test fails because cw v1's
   implementation diverges from JVM semantics.
2. **An intentional skip** — the ported test references a JVM
   feature cw v1 has explicitly deferred or excluded (Tier B /
   C / D per ADR-0013).

Without a structured skip taxonomy, every Tier B/C/D-touching
test is a false-positive gate failure that the loop must
"explain away" in commit messages or skip comments. That
accumulates into the same opaque ad-hoc state the per-phase
expansions were designed to prevent.

§9.13 placeholder originally named the deferred ADR
"ADR-0025"; that slot collides with ADR-0025 (chapter archive
boundary, 2026-05-25). Per CLAUDE.md § Project spirit ("ADR
numbers are time-ordered max+1 at issue time"), the upstream
skip taxonomy ADR mints as **ADR-0046** (next free slot at
issue time).

## Decision

Land `test/clj/skip_taxonomy.yaml` as the SSOT for which
upstream tests are skipped from the Tier A gate and why.
Schema:

```yaml
version: 1
last_updated: YYYY-MM-DD

skipped:
  - test_file: "clojure/test/test_helpers.clj"
    test_name: "test_something"
    tier: D                # A | B | C | D (per ADR-0013)
    reason: "Requires gen-class which is Tier D per ADR-0013."
    recall_trigger: "(none — Tier D permanent)"
    last_reviewed: "YYYY-MM-DD"
```

- `tier:` field maps to ADR-0013's classification — A (in scope,
  bug), B (recommended), C (Tier C reflective), D (permanent
  exclusion).
- `reason:` is a sentence the gate prints when the test is
  skipped, sufficient for the user to triage without reading
  this ADR.
- `recall_trigger:` is the testable predicate that, when true,
  re-includes the test (typically "when D-NNN closes" or
  "(none — Tier D permanent)").
- `last_reviewed:` is the date a human re-confirmed the skip is
  still appropriate. `audit_scaffolding` periodic sweeps flag
  entries older than 90 days for re-evaluation.

The Tier A gate (`test/run_all.sh::test_clj`) reads
`skip_taxonomy.yaml`, runs only tests NOT in the skipped set,
and asserts 100% PASS. A failing test that is not in the
skip set is a gate failure (loud red). A test in the skip set
that suddenly starts passing is a separate audit row (not a
gate failure but worth surfacing — "the recall_trigger may
have closed").

## Why now (Phase 11 row 11.1)

Row 11.2 (clojure.test minimum surface) ships the
`deftest` / `is` / `run-tests` macros that the ported tests
will use. Row 11.3 (porting upstream tests) needs the skip
taxonomy active before the gate can usefully count "Tier A
100% PASS". The taxonomy SCHEMA mints here so rows 11.3 + 11.4
can reference an existing SSOT shape from the moment they open.

The actual `skip_taxonomy.yaml` FILE is created at row 11.3
when the first ported test surfaces a skip-worthy case.

## Alternatives considered

**Alt 1 — Inline skip comments in each ported test**. Rejected:
matches what cw v0 did, doesn't scale; the loop has no
machine-readable way to count "Tier A pass rate" or to detect
stale skips. The yaml SSOT is the single point of truth.

**Alt 2 — Use upstream's `:test/skip` metadata directly**.
Partial: JVM's test metadata is per-fixture annotation; cw v1's
ported tests would need to carry the same metadata. The skip
taxonomy yaml CAN coexist with `:test/skip` metadata — for
cycle 1, the yaml is the SSOT and `:test/skip` is not parsed.

**Alt 3 — Reuse `feature_deps.yaml` for skip tracking**.
Rejected: `feature_deps.yaml` already tracks PROVISIONAL
behaviour with a different lifecycle. Mixing test-corpus skip
rows in there bloats its schema. A separate yaml is cleaner.

## Consequences

**Positive**:
- Gate failures are unambiguous (true bug vs intentional skip).
- `audit_scaffolding` can sweep `skip_taxonomy.yaml` for stale
  entries the way it sweeps `debt.md`.
- Future cycles that close a `D-NNN` can grep
  `skip_taxonomy.yaml` for matching `recall_trigger` rows and
  re-include the affected tests automatically.

**Negative**:
- One more SSOT file to maintain. Mitigation: only update when
  porting a test that needs a skip; otherwise it lives
  read-only.

## Affected files

- `.dev/decisions/0046_upstream_skip_taxonomy.md` (this file)
- `test/clj/skip_taxonomy.yaml` (created at row 11.3 first
  skip-worthy port)
- `test/run_all.sh` `test_clj` step (added at row 11.4)
- `.dev/debt.yaml` D-NNN rows that the Tier A gate's
  `recall_trigger` field references

## References

- ADR-0013 (Tier D permanent — the tier classification this
  taxonomy uses)
- ADR-0021 (Test layer taxonomy — Layer 5 Conformance opens
  at Phase 11)
- §9.13 Phase 11 task list (rows 11.2 / 11.3 / 11.4 use this
  ADR's SSOT)
