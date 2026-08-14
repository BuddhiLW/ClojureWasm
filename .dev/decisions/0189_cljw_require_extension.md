# 0189 — `.cljw` is a source extension `require` resolves

- **Status**: Proposed
- **Date**: 2026-08-14
- **Author**: BuddhiLW
- **Tags**: require, classpath, dialects, cljc, conformance

## Context

ADR-0188 gave cljw a *name* inside a portable file: `{:cljw, :clj, :default}`
lets a `.cljc` say "on this runtime, the answer is different". That closed the
expression gap at the level of a **form**.

The gap it did not close is at the level of a **file**. `filesystemResolver`
(ADR-0084, D-158) probed exactly two extensions:

```zig
const exts = [_][]const u8{ ".clj", ".cljc" };
```

so a namespace whose cljw implementation differs *structurally* from the JVM
one — different requires, different deftypes, a different set of top-level
forms — has nowhere to live. The author's only options are:

1. Put everything in one `.cljc` and reader-condition the whole file. This is
   what `#?` is for at the granularity of an expression; at the granularity of
   a file it produces a source where the two runtimes' code is interleaved
   line by line and neither reads as a program.
2. Ship a `.clj` and let cljw load it. That is what happens today, and it is
   the reason cljw is currently indistinguishable from Clojure at the
   filesystem layer: **cljw code and JVM code are the same files with the same
   names**, so nothing — not the runtime, not an editor, not an indexer —
   can tell which runtime a given source was written for.

Every other dialect in the family already resolves its own extension:
ClojureScript probes `.cljs` then `.cljc`; Basilisp `.lpy`; Babashka `.bb`;
ClojureCLR `.cljr`; clojurust `.cljrs`. cljw was the only one whose "native"
sources were spelled with another runtime's extension.

The measured state before this decision (cljw 1.10.2, 2026-08-14):

```
$ cljw -cp . main.clj          # probe/lib.cljw on the classpath
cljw FAILED: Could not locate 'probe.lib' on the require resolver
$ cljw script.cljw             # positional script path
:script-ran-from :cljw-ext     # already worked — no extension check there
```

The positional-script path never inspected the extension, so `cljw foo.cljw`
already ran. Only `require` was closed, which is the inconsistency this
decision removes.

## Decision

`require` probes three extensions at each classpath root, in this order:

```zig
pub const search_exts = [_][]const u8{ ".cljw", ".clj", ".cljc" };
```

**`.cljw` is probed first.** A `foo/bar.cljw` beside a `foo/bar.clj` is the
file cljw loads. This is the same precedence ClojureScript gives `.cljs` over
`.cljc`: the dialect-native extension is by construction the more specific
statement about *this* runtime, so it wins where both exist.

**Root order still dominates extension order.** The search is root-major —
for each root in `load_paths`, try each extension — so an earlier classpath
root holding `bar.clj` wins over a later root holding `bar.cljw`. That is JVM
classpath semantics (first root wins), and extension precedence is a
within-root tiebreak, never a cross-root one.

**The order is the contract**, so it is pinned by name (`search_exts`) and
asserted directly, not only end-to-end. A reordering is otherwise silent:
every project carrying only one of the three extensions resolves identically
under any order, and only a project carrying two can observe the difference.

Backward compatibility is total by the same argument ADR-0188 made: the list
only grows, and nothing in the wild currently ships a `.cljw` file, so every
existing project resolves the exact file it resolved before.

## Alternatives considered

### Alternative A — leave it at `{.clj, .cljc}`

- **Sketch**: cljw keeps loading `.clj`. Structural divergence is expressed by
  reader-conditioning a `.cljc`, or by shipping a separate namespace name
  (`foo.bar-cljw`).
- **Why rejected**: a whole-file `#?` split is not a readable program, and a
  separate *namespace* is worse than a separate *file* — it changes the name
  callers must write, so every consumer becomes runtime-aware. The point of a
  per-dialect extension is that the namespace stays `foo.bar` and only the
  implementation swaps. It also leaves cljw as the only dialect in the family
  with no extension of its own, which is the observation that prompted this.

### Alternative B — `.cljw` probed LAST (after `.cljc`)

- **Sketch**: same three extensions, order `{.clj, .cljc, .cljw}`, so `.cljw`
  is a fallback rather than an override.
- **Why rejected**: it inverts what the extension means. `.cljw` would then
  only ever load when no portable or JVM source exists — i.e. exactly when the
  override is *not* needed. An override that loses to the thing it overrides
  cannot express "on cljw, use this instead", which is the entire use case.

### Alternative C — `.cljw` REPLACES `.clj` in the probe list

- **Sketch**: cljw stops reading `.clj` at all; `{.cljw, .cljc}`.
- **Why rejected**: it would break every library cljw currently loads. The
  `docs/works/ladder.md` corpus is `.clj` and `.cljc`; refusing `.clj` would
  un-load all of it overnight. This is the file-level twin of ADR-0188's
  rejected Alternative B, and fails for the same reason: cljw genuinely is a
  Clojure runtime and should keep reading Clojure.

### Alternative D — make the extension list CLI-configurable

- **Sketch**: `--source-exts cljw,clj,cljc`.
- **Why rejected**: speculative generality, and it makes a project's meaning
  depend on an invocation flag — the same tree would resolve to different
  files under different commands. Same objection as ADR-0188's Alternative C,
  and it can be added later additively if a real second consumer appears.

## Consequences

- **Positive**: a namespace can carry a cljw-specific implementation under its
  own extension, with the namespace name unchanged, so consumers need not know
  which runtime they are on.
- **Positive**: cljw sources become *identifiable*. An indexer, an editor mode
  or a build can tell cljw code from JVM code by path, which is what makes
  per-dialect tooling (carto lang provenance, per-dialect source roots)
  possible at all.
- **Positive**: closes the inconsistency where `cljw foo.cljw` ran as a script
  but `(require 'foo)` could not find the same file.
- **Negative**: a project may now carry `bar.cljw` and `bar.clj` that drift
  apart, with cljw silently loading one and clj the other. That is inherent to
  per-dialect extensions (cljs has had it since 2011); the mitigation is the
  same one cljs uses — prefer `.cljc` with `#?` for anything that can be
  shared, and reach for `.cljw` only for genuine structural divergence.
- **Neutral**: no effect on any existing project. Nothing in the wild ships a
  `.cljw` file, and both `.clj` and `.cljc` keep their relative order.

## Affected files

- `src/lang/require_resolver.zig` — `search_exts` (new named pub const, was an
  inline two-element array) + the module and fn doc comments; one unit test
  pinning the probe order.
- `src/app/cli.zig` — `-cp` help text now names the three extensions in order.
- `test/e2e/phase15_require_fs.sh` — `.cljw` resolution, `.cljw`-beats-`.clj`,
  `.clj`-still-beats-`.cljc`, cross-extension require, and root-order-beats-
  extension-order (11 cases, was 6).
- `docs/works/README.md` — the classpath paragraph states the three-extension
  probe order.

## References

- ADR-0084 / D-158 — the filesystem require resolver this extends.
- ADR-0188 — `:cljw` as a reader-conditional feature; the form-level twin of
  this file-level decision. The backward-compatibility argument is the same.
- ClojureScript's `.cljs` > `.cljc` resolution — the precedent for probing the
  dialect-native extension first.
