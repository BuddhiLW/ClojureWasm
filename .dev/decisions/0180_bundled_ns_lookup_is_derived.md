# ADR-0180 — a bundled file's namespace is a field, not a second list

- Status: Proposed → Accepted
- Date: 2026-08-04
- Supersedes: none
- Related: ADR-0163 (lazy bootstrap regions), ADR-0178 (placement.yaml is
  generated), D-569

## Context

`src/lang/bootstrap.zig` had two ways to answer "which bundled file defines
namespace N", maintained differently.

`FILES` rows carried a display **label** (`<clojure.set>`), and
`nsNameFromLabel` recovered the namespace from it by stripping the angle
brackets — with `<bootstrap>` → `clojure.core` special-cased. Four call sites
used that (`markFilesLoaded`, the eager-region walk, the source registry) plus
`builder.zig`'s region keying. Alongside it sat `lookupEmbeddedFile`, a
**hand-written** chain of 30 `if (mem.eql(u8, ns_name, "…")) return FILES[N];`
over 32 rows.

The first draft of this ADR argued that the chain was dangerous because it had
drifted: `clojure.repl` has a `FILES` row but no chain row, so a build without a
region blob could not resolve it. **A devil's-advocate review falsified that,
and the truth is a stronger argument, so it replaces it here.**

`loadCore` calls `markFilesLoaded(rt, ACTIVE_FILES)` (`bootstrap.zig:351`)
before evaluating anything, and `builder.zig:230` does the same for
`cache_gen`. Every bundled namespace is therefore in `rt.loaded_libs` from the
start, and `loadOrFindNs` returns at `loader.zig:121` before consulting any
resolver. The shipped binary additionally carries a region for every
`ACTIVE_FILES` row, and `loadOrFindNs` checks the region blob before the
resolver. Measured on the built binary: `(require 'clojure.repl)` and
`(require 'clojure.core-meta)` both already succeed.

So the chain has **no production consumer for any bundled name**. Its only live
callers were its own unit tests. A hand-maintained table whose correctness
nobody can observe is worse than a drifting one — drift at least eventually
shows up.

That also settles the question this ADR had to answer before deleting anything:
*do the two lists encode genuinely different things — "is bundled" versus "is
publicly requireable" — and would collapsing them lose an intentional
distinction?* **No.** The one exclusion the code claimed to enforce
(`clojure.core-meta`, with a comment saying so) is not enforced: requiring it
works today via `loaded_libs`. The distinction has never held. A partial second
list is worse than none, and D-569's own proposed shape — move the exclusions
onto `FileEntry` as a field — would have made a field out of a distinction that
does not exist.

Ten comments in `FILES` exist only to defend the index keying — *"appended last
so earlier `FILES[N]` indices stay stable"* — so the ordering of the
bundled-source table has been shaped ten times by a constraint belonging to a
function nothing calls.

## Decision

**`FileEntry` carries `ns` as a first-class field. The label is derived from
it, not the other way round.**

```zig
fn f(comptime ns: []const u8, comptime path: []const u8) FileEntry {
    return .{ .ns = ns, .label = defaultLabel(ns), .source = embedSrc(path) };
}
```

`clojure.core` is the single row that overrides its label (`<bootstrap>`), which
is exactly where that special case belongs — on the row it describes, rather
than inside a shared helper four callers had to route through.

`nsNameFromLabel` is deleted. All five call sites wanted the namespace and none
wanted the label; that they went through a label-un-decorator is the evidence
that the derivation ran backwards.

The lookup iterates `ACTIVE_FILES`:

```zig
fn lookupEmbeddedFile(ns_name: []const u8) ?FileEntry {
    for (ACTIVE_FILES) |file| {
        if (std.mem.eql(u8, file.ns, ns_name)) return file;
    }
    return null;
}
```

`ACTIVE_FILES` — not `FILES` filtered by `isActiveFile` at run time. It *is*
`FILES` filtered by `isActiveFile`, at comptime. Iterating it makes the
resolver/walk coupling structural instead of re-derived, and the resolver
finally joins the set of walkers `ACTIVE_FILES`'s own doc comment describes.

A **comptime uniqueness assertion** over `ns` is added. First match wins in
every namespace lookup here — the resolver, the region key, `markFilesLoaded` —
so a duplicate would shadow silently. Neither the chain nor a naive loop can
detect that; deriving is the moment to fix it rather than inherit it. Verified
by renaming one row to collide: `error: two bundled files claim the namespace
clojure.walk`, at compile time.

The `FILES` ordering constraint is lifted with the ten comments defending it.
Load ORDER still matters — `core.clj` first, `clojure.data` after
`clojure.set`, and so on — because that is a real constraint about what has
interned what. What is gone is the unrelated one about indices not shifting.

### The coupling test asserts both directions now

It previously asserted only that an **inactive** file is absent from both
`ACTIVE_FILES` and the lookup, with a comment stating that an active file "need
not be name-resolvable". That absence is what let a 30-`if` chain sit beside
`FILES` and disagree with it.

It now also asserts that every active file resolves to itself. Under the
derived lookup that is close to a tautology, and the test says so in a comment:
it is a **tripwire against reintroducing a hand-written second table**, not a
correctness check. A future reader must not delete it as vacuous.

## Consequences

- One list. A new bundled namespace is one row, placed where it reads best.
- `(require 'clojure.repl)` / `(require 'clojure.core-meta)` now also resolve
  through the source path. Nothing depended on them being declined: every
  consumer of `embeddedResolver` / `chainedResolver` was traced, and the
  filesystem resolver never gets a shot at a bundled name in any configuration
  because `loadOrFindNs` short-circuits first. Verified empirically that a
  user's own `clojure/repl.clj` on `-cp` does not shadow today and does not
  after this change.
- A duplicate namespace is a compile error rather than a silent shadow.
- Performance is not a question worth hedging about: the call site fires once
  per `require`, only when both `loaded_libs` and the region blob miss — which
  is never, in the shipped binary. `sourceText` already runs the identical
  linear scan over `ACTIVE_FILES` on the strictly hotter error-render path.
- D-569 is discharged, and its status text — which asserted the same
  unreproducible failure this ADR's first draft did — is corrected rather than
  left as a record of something that never happened.

## Alternatives considered

*(Devil's-advocate fork, fresh context, verbatim. Its "facts checked first"
preamble is preserved in full: three of its findings falsified the draft's
Context, and one of them — that `clojure.core-meta` is not actually withheld —
is the decisive evidence for the Decision.)*

### Facts checked first (three of them change the draft)

**(a) The Context's failure story does not reproduce.** The draft says that in a build without a region blob — "the unit-test runtime, the `cache_gen` host tool" — `(require 'clojure.repl)` cannot resolve. Neither named configuration can reach `lookupEmbeddedFile` for a bundled name:

- The source path: `loadCore` (`src/lang/bootstrap.zig:351-352`) calls `markFilesLoaded(rt, ACTIVE_FILES)` and then `loadCoreFiles(…, ACTIVE_FILES)`. Every bundled namespace is put in `rt.loaded_libs` *and* evaluated into the env, so `loadOrFindNs` returns at `src/eval/loader.zig:121-123` before any resolver is consulted. There is no laziness in the source path at all.
- `cache_gen` goes through `builder.buildBootstrapEnvelope`, which calls `bootstrap.markFilesLoaded(rt, files)` at `src/app/builder.zig:230` before the compile loop — the same early return.
- The shipped binary carries a region for *every* `ACTIVE_FILES` row (`src/app/builder.zig:272-276`), including `clojure.repl` and `clojure.core-meta`, and `loadOrFindNs` consults the region blob first (`src/eval/loader.zig:126-136`).

Empirically, on the current `zig-out/bin/cljw`: `(do (require 'clojure.repl) (clojure.repl/demunge "a_QMARK_"))` → `"a?"`; `(do (require 'clojure.core-meta) :okmeta)` → `:okmeta`. Both already work.

**(b) Therefore `lookupEmbeddedFile` has no live production caller for any bundled name.** Its only live callers today are its own unit tests (`src/lang/bootstrap.zig:853-876`, `:917`). The single production path that could still reach it is a *forward-reference* `(:require later-bundled-ns)` from inside a bundled file during `cache_gen`, where `loaded_libs` hits but `env.findNs` misses (`src/eval/loader.zig:121-123`) — and no bundled file does that today, because load order is arranged so dependencies come first.

This weakens the ADR's motivation and strengthens its conclusion. The second list is not merely drifting; it is a hand-maintained table with **zero production consumers**, whose correctness nobody can observe. That is a stronger argument for deriving it than the one the draft makes, and it should replace the Context's "dangerous silent gap" narrative, which as written is not true.

**(c) The `clojure.core-meta` "deliberate withholding" is already unenforced.** The comment at `src/lang/bootstrap.zig:303-307` presents core-meta's absence as intentional ("it is in `EAGER_NS`, loaded at startup, never required"). But `(require 'clojure.core-meta)` succeeds today via `loaded_libs`. The asymmetry the second list claims to encode has never held. This is the decisive answer to "do the two lists encode genuinely different things — 'is bundled' vs 'is publicly requireable'?" **They do not.** One list claims a distinction the runtime does not implement. Under F-013's own reasoning ("a partial class is a worse trap than an absent one"), a partial second list is worse than none.

Two smaller corrections: the chain is **30** `if` statements (`grep -c 'if (std.mem.eql(u8, ns_name'`) over **32** `FILES` rows, not 31; and there are **10** index-stability comments (lines 131, 141, 148, 151, 154, 157, 169, 175, 184, 188), not eight — the debt row D-569 says three. Use the measured numbers.

### Alt 1 — smallest-diff: add the two missing rows, keep index keying

Append `if (std.mem.eql(u8, ns_name, "clojure.core-meta")) return FILES[29];` and the `clojure.repl` → `FILES[30]` row, and add the positive-direction assertion to the coupling test.

*Better:* one commit, no structural claim to defend; preserves whatever a reader thought the `FILES[N]` indices meant; keeps `embeddedResolver` able to decline a name in the future, should a policy of "bundled but not requireable" ever become real.

*Breaks:* nothing mechanically — and that is the objection. It re-affirms a table with no production consumer, keeps the ordering constraint that has already deformed the `FILES` table ten times, and makes the positive-direction test a genuine (not tautological) assertion that will fail on the *next* forgotten row rather than preventing it. Under F-002 this is the Smallest-diff bias: it optimises for the size of this commit against the shape of the file. Reject.

### Alt 2 — finished-form-clean: the namespace is the fact; the label is presentation

Recommended. The draft derives the namespace *from* the display label; the finished form runs the derivation the other way.

`FileEntry` gains `ns: []const u8` as a first-class field. `label` stays (it is the error-renderer's `SourceContext` key and the sources-blob key, `src/lang/bootstrap.zig:216-246`) but becomes derived-or-overridden: `<clojure.set>` is `"<" ++ ns ++ ">"`; `clojure.core`'s `<bootstrap>` is the one explicit override. `nsNameFromLabel` (`src/lang/bootstrap.zig:769-774`) is deleted; its five production call sites (`src/lang/bootstrap.zig:706, 714, 738, 755`; `src/app/builder.zig:272`) become `file.ns`. Every one of those five wants the namespace — none wants the label — which is the evidence that the current derivation direction is backwards: a `<bootstrap>` special case exists in a shared helper solely so four callers can un-decorate a string that was decorated for the renderer's benefit.

Then:

```zig
fn lookupEmbeddedFile(ns_name: []const u8) ?FileEntry {
    for (ACTIVE_FILES) |file| {
        if (std.mem.eql(u8, file.ns, ns_name)) return file;
    }
    return null;
}
```

Note `ACTIVE_FILES`, not `FILES` + `isActiveFile`. `ACTIVE_FILES` (`src/lang/bootstrap.zig:199-209`) *is* `FILES` filtered by `isActiveFile` at comptime. Iterating it makes the resolver/walk coupling **structural** rather than re-derived, and the resolver finally joins the set of walkers that `ACTIVE_FILES`'s own doc comment describes.

Add a comptime uniqueness assertion over `ns` (a `comptime { }` block or a `StaticStringMap` construction that would fail on a duplicate key). Neither the chain nor the draft's loop detects a duplicate — both silently take the first match. Today the 32 labels are unique and `nsNameFromLabel` is injective over `FILES` (verified), and the plausible near-term collisions the review asked about (`cljw.json` vs `clojure.data.json`) are distinct names. But "unique today" is exactly the property a derived design should assert rather than assume, and it is the one real hazard first-match ordering introduces.

*Better:* one fact per row, stated where a reader is already looking; the `FILES` ordering is governed only by load order (a real constraint); the ten "appended last" comments go; the `<bootstrap>` special case shrinks from a shared helper to one field on one row; a duplicate namespace becomes a compile error instead of a silent shadow.

*Breaks:* the diff is larger than the draft's — a new field on 32 rows, a deleted public helper, five updated call sites, and `ACTIVE_FILES`'s doc comment (`src/lang/bootstrap.zig:196-198`) rewritten, since it currently asserts "`FILES` keeps its full shape (and its stable indices) so `lookupEmbeddedFile` stays index-keyed", which this ADR falsifies. Per F-002 and the Cycle-budget-defer smell, size is not a reason to prefer the draft's shape; recommend Alt 2 as written.

### Alt 3 — wildcard: delete the embedded resolver entirely

Given finding (b), the honest wildcard is to remove `lookupEmbeddedFile`, `embeddedResolver`, and `installEmbeddedResolver` (`src/lang/bootstrap.zig:265-336`), have `setupCorePrefix` install nothing, and let bundled-namespace resolution rest on the two mechanisms that actually serve it: `loaded_libs` (source path, `cache_gen`) and the region blob (shipped binary). `chainedResolver` (`src/lang/require_resolver.zig:90-93`) collapses to `filesystemResolver`, and the "bundled namespaces can never be shadowed" guarantee moves to the region blob — where it already lives in practice (verified: a user `clojure/repl.clj` and a user `clojure/set.clj` on `-cp` both fail to shadow today).

*Better:* the largest reduction — it deletes a mechanism instead of maintaining one, and removes the only place where a "bundled" namespace could be served from two different sources.

*Breaks:* it forecloses the eager→lazy switch that `src/lang/bootstrap.zig:169-170` explicitly reserves ("the list stays data-driven so a future eager→lazy switch (lazy-AOT, deferred) is local"). A source-path bootstrap that stops eagerly loading all 32 files would need exactly the resolver this alternative deletes. It also removes the honest "namespace not found" for `cljw.wasm` in a non-`-Dwasm` build by removing the code path rather than by keeping the gate, and it deletes four unit tests that are currently the only executed proof that the bundled sources decompress and parse. Not recommended, but recorded because it names the real question the draft only half-asks: *why does a second resolution mechanism exist at all?*

### Attacks on the draft that survive

1. **The Context is factually wrong and must be rewritten** (finding (a)). Left as-is, the ADR records a failure mode that cannot occur, which is the exact defect class ADR-0178 was written against.
2. **The draft's point 2 rests on a premise that is already false** (finding (c)). Its argument — "core-meta is withheld, but withholding is harmless, so no exception mechanism is needed" — reaches the right conclusion from a wrong premise. Core-meta is not withheld. Say so; it is the strongest evidence in the ADR that the two lists do not encode different things, and it also disposes of D-569's own SHAPE proposal ("move the two deliberate exclusions onto the `FileEntry` as a field"), which would have made a field out of a distinction that does not exist.
3. **`FILES` + `isActiveFile` should be `ACTIVE_FILES`.** The draft's point 3 claims uniform gating as a win, but re-applies at run time a predicate already applied at comptime. This is a smallest-diff residue. (The gate itself *is* a no-op as claimed — `isActiveFile` is `build_options.wasm or !entry.wasm_only` (`src/lang/bootstrap.zig:71-73`) and only `FILES[23]` `<cljw.wasm>` sets `wasm_only`. Verified.)
4. **Nothing depends on the resolver declining `clojure.repl` or `clojure.core-meta`.** Traced every consumer: `chainedResolver` (`src/lang/require_resolver.zig:91`), `installChained` from `builder.zig:387` / `runner.zig:113` / `repl.zig:131`, `installEmbeddedResolver` from `setupCorePrefix` (`bootstrap.zig:525`), and the single read at `loader.zig:137`. The filesystem resolver never gets a shot at a bundled name in any configuration, because `loadOrFindNs` short-circuits on `loaded_libs` or the region blob first. Verified empirically with a user-supplied `clojure/repl.clj` on `-cp`: it does not shadow today and will not after the change.
5. **First-match ordering is unasserted.** Add the comptime uniqueness check (Alt 2). The chain had the same defect; deriving is the moment to fix it, not to inherit it.
6. **Performance is a non-question, and the ADR should say why rather than hedge.** The call site is `loadOrFindNs`, once per namespace `require`, only when both `loaded_libs` and the region blob miss — which is never, in the shipped binary. For scale: `sourceText` (`src/lang/bootstrap.zig:216-246`) already runs the identical linear `mem.eql` scan over `ACTIVE_FILES` *and then* a full walk of the compressed sources blob, on the error-render path, which is strictly hotter. The draft's "the chain of 31 `if`s it replaces was the same scan written out" is correct but understates the case.
7. **The coupling test.** Under Alt 2 both directions become tautological, and the draft's stated rationale ("close to a tautology, which is the point") is the right one — but the ADR should say plainly that the test is a *tripwire against reintroducing a hand-written table*, not a correctness check, so a future reader does not delete it as vacuous.

**Adopted: Alt 2**, with every one of the seven attacks applied — the Context
rewritten to the measured facts, `ACTIVE_FILES` instead of a re-derived gate,
the comptime uniqueness assertion (falsified by inducing a collision), the
tripwire rationale written into the test, and the corrected counts (30 `if`s,
32 rows, 10 comments) used throughout.

## Revision history

- 2026-08-04: Proposed → Accepted. First draft's Context was falsified by the
  DA fork and replaced; the DA's own finding (c) became the Decision's central
  argument.
