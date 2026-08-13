# 0188 — `:cljw` joins the reader-conditional platform feature set

- **Status**: Proposed
- **Date**: 2026-08-13
- **Author**: BuddhiLW
- **Tags**: reader, cljc, conformance, dialects

## Context

cljw's reader-conditional feature set was `{:clj, :default}` (ADR/D-232,
`src/eval/reader.zig`). The reasoning was sound as far as it went: cljw
implements Clojure, not ClojureScript, so a `.cljc` file's `:clj` branch is
the branch cljw should read.

What that set cannot express is **where cljw is not the JVM**. The set says
"I am clj" and nothing else, so a `.cljc` file has no way to name this
runtime — every divergence reads as the JVM branch and then fails.

The concrete forcing case is the `clojure.core` compliance suite
(jank-lang/clojure-test-suite): 249 `.cljc` namespaces, one per core symbol,
whose entire method of recording a dialect's behaviour is a reader
conditional. Upstream already carries `:cljs`, `:cljr`, `:bb`, `:lpy`,
`:phel` and `:jank` branches, and its `portability.cljc` dispatches
`big-int?`, `sleep`, `lazy-seq?` and the `p/thrown?` `assert-expr`
multimethod on exactly those keys. jank names itself `:jank`; Basilisp
`:lpy`; Phel `:phel`; clojurust `:rust`. Under `{:clj, :default}` cljw would
run every JVM branch verbatim, including the ones that assert
`clojure.lang.LazySeq` or a `Thread/sleep`, and its real divergences would
land in the suite as ordinary red tests with nowhere to be recorded.

That is the same failure the accepted-divergence ledger exists to prevent
(`.claude/rules/accepted_divergences.md`): a divergence that cannot be
*written down* gets re-discovered every sweep and reads as breakage rather
than as design.

The suite is also the reason this is not hypothetical alignment work. It is
the mechanism by which cljw's clj-parity gets measured against the same
oracle every other dialect is measured against — a public, per-symbol
compliance surface that `clj_diff_sweep` (one-expression-at-a-time, locally
authored) does not provide.

## Decision

cljw's platform feature set becomes `{:cljw, :clj, :default}`.

Selection stays exactly as it was: scan clauses left-to-right, read the first
whose key is in the set. `:cljw` therefore wins only where an author put it
*ahead of* `:clj`, which is what makes the change backward-compatible —
every existing `.cljc` in the wild has no `:cljw` clause, so it selects the
same branch it selected before, and one that writes `#?(:clj a :cljw b)`
still gets `a`.

The set lives in one predicate, `Reader.isPlatformFeature`, consulted by both
`readReaderConditional` and `readReaderConditionalSplice`. The two paths
previously carried the same two-way `or` chain twice; a reader whose `#?`
and `#?@` disagreed about the feature set would select different branches in
the same file, which is a silent-wrong-code failure rather than an error.

Naming: `:cljw` matches the binary, the package, and the project's own
short name, and matches how every other dialect keys itself (`:jank`,
`:lpy`, `:phel`, `:rust`).

## Alternatives considered

### Alternative A — keep `{:clj, :default}`; encode divergences elsewhere

- **Sketch**: leave the reader alone. Record cljw's divergences from the
  suite in `.dev/accepted_divergences.yaml` only, and carry a local skip-list
  of test namespaces.
- **Why rejected**: the ledger records *that* cljw diverges; the suite is
  about *what the expected value is on this runtime*. A skip-list deletes the
  assertion instead of restating it, so the divergent behaviour stops being
  pinned — the exact property the AD `pin` field exists to guarantee. It also
  makes cljw the only dialect in the suite that cannot state its own
  expectation, which pushes the divergence into a fork of the test files.

### Alternative B — `:cljw` REPLACES `:clj`

- **Sketch**: the set becomes `{:cljw, :default}`; cljw stops claiming to be
  `:clj`.
- **Why rejected**: it would break every `.cljc` library cljw currently
  loads. The whole `docs/works/ladder.md` corpus depends on `#?(:clj …)`
  selecting the JVM-shaped branch, because that branch is the one written
  against `clojure.core` rather than against `js/`. cljw genuinely is a
  Clojure runtime; dropping the claim would be false as well as costly.

### Alternative C — a build-time / CLI-configurable feature set

- **Sketch**: `--reader-features cljw,clj` so the suite can run cljw in a
  "strict cljw" mode where `:clj` is absent.
- **Why rejected**: speculative generality for one consumer, and it makes a
  file's meaning depend on an invocation flag — the same source would read as
  two different programs. If a strict mode is ever genuinely wanted (for
  measuring "how much of the JVM branch am I riding?"), it can be added then,
  and it is additive to this decision rather than an alternative to it.

## Consequences

- **Positive**: `.cljc` files can name cljw. The compliance suite can carry
  cljw expectations in-tree instead of in a fork, and cljw joins the same
  per-symbol parity measurement as jank / Basilisp / Phel / clojurust.
- **Positive**: `#?` and `#?@` can no longer drift apart on the feature set.
- **Negative**: one more key that authors may reach for where `:default`
  would have been the honest answer. A `:cljw` branch asserting cljw's
  behaviour is a *recorded* divergence, so it should be paired with an
  `AD-NNN` when the divergence is intentional, and with a debt row when it
  is a gap — the reader change does not itself classify anything.
- **Neutral**: no effect on any existing file. The set only grows, and the
  new key is one nothing in the wild currently writes.

## Affected files

- `src/eval/reader.zig` — `isPlatformFeature` predicate; both `#?` and `#?@`
  consult it.
- `test/e2e/phase15_reader_conditional.sh` — `:cljw` selection, `:clj`-first
  precedence, lone `:cljw`, and `#?@` parity (14 cases, was 10).
- `docs/works/README.md` — the `.cljc` paragraph now states the three-key set.

## References

- D-232 — the original `#?` implementation.
- `.claude/rules/accepted_divergences.md` — why an unrecordable divergence is
  the failure mode this decision removes.
- <https://github.com/jank-lang/clojure-test-suite> — the compliance suite;
  `test/clojure/core_test/portability.cljc` is its per-dialect dispatch point.
