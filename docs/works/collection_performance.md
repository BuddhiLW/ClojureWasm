# Collection performance — cljw against JVM Clojure, measured

The question this page answers came from a user: *for performance, should cljw
reimplement the same immutable algorithms core Clojure does?*

It is answered by measurement rather than by reading either implementation. The
internal ledger of individual optimizations lives in `.dev/optimizations.md`;
this page is the user-facing view — what you can expect, and where cljw is still
slower.

**Short version.** The persistent data structures are in the same league as the
JVM's, trading wins op by op. The *interpreter* is far behind the JVM's JIT and
will stay behind until cljw compiles. Every catastrophic gap ever measured here
turned out to be a specific algorithmic mistake in cljw, not a consequence of
Zig-vs-Java or of the GC; three of the four found so far are fixed, and one
remains.

## Method

`.dev/bench/scaling_form.edn` runs a **fixed** number of operations against
collections of growing size `[1000 4000 16000]`, after warmup iterations so the
JVM has JIT-compiled. Flat wall-clock across sizes means the operation is
O(1)/O(log n) per call; time growing with the size factor means O(n).

Both runtimes are exercised on the same box, same probe, in the same session:
cljw built `-Doptimize=ReleaseSafe`, against JVM **Clojure 1.12.4**. Numbers
below are at **n = 16000**. Reproduce with:

```sh
cljw .dev/bench/scaling.clj      # cljw side, human-readable
```

Sub-microsecond results are reported best-of-7 with an empty-loop baseline
subtracted — without that, per-call noise and loop overhead swamp the signal and
produce confident-looking nonsense in both directions.

## Two different questions, which are easy to conflate

### 1. Interpretation speed — the JVM is far ahead

| per 20000 iterations | clj 1.12.4 | cljw |
|---|---|---|
| empty `dotimes` | **0.043 ms** | 0.900 ms |

An empty loop costs cljw ~45 ns per iteration against the JVM's ~2.2 ns. That is
not Zig losing to Java. It is an **interpreter** (tree-walk / VM) losing to a
**JIT** that has compiled the loop to native code with the induction variable in
a register. No amount of collection work changes it; only a compiler would. This
is tracked as the runtime's own "gap area III" (fusion → a narrow ARM64 JIT).

Every number in the next section carries this overhead. Read them as *relative*
structural cost, not as a language comparison.

### 2. The persistent structures themselves — same league, trading wins

| per 20000 ops, n=16000 | clj 1.12.4 | cljw | faster |
|---|---|---|---|
| vector `assoc` (mid) | 49.38 ms | **21.43 ms** | cljw, 2.3× |
| map `assoc` | 73.93 ms | **18.77 ms** | cljw, 3.9× |
| vector `nth` | **0.373 ms** | 0.879 ms | clj, 2.4× |
| map `dissoc` | **2.62 ms** | 8.15 ms | clj, 3.1× |
| vector `conj` | **1.75 ms** | 7.62 ms | clj, 4.4× |

cljw is ahead on both `assoc`es — its bump-allocating GC makes the path-copy
cheaper — and behind on `conj` and `dissoc`. There are no 1000× effects in
either direction once the algorithms match.

So: this is not "Zig beats the JVM". It is "the data structures are sound, and
the catastrophic numbers are bugs."

## The catastrophic gaps were all algorithmic

Four operations were once 1000×–7000× slower than JVM Clojure. Every one was a
specific mistake, of exactly two kinds.

**An abstraction-barrier violation** — the Clojure layer re-implementing an
operation the Zig layer already provided correctly:

| op | was | now | vs clj |
|---|---|---|---|
| `pop` (vector) | 8278 ms | **2.47 ms** | 1.93 ms — within 1.3× |
| `count` (list) | 481 ms | **0.19 ms** | 0.18 ms — parity |

`pop` was `(into [] (take (dec (count coll)) coll))` in `core.clj`, rebuilding a
whole fresh trie, while `vector.zig` already had a faithful
`PersistentVector.pop()` that nothing called. `count` on a list walked the chain
even though every cons cell already stored its length — the stored number was
distrusted because a cell can head a mixed chain where it means something else.
The fix was to make the field say *when* it is exact, not to compute it again.

**Materialising where Clojure keeps a view** — the more systemic kind:

| op | was | now | vs clj |
|---|---|---|---|
| `seq` (vector) | 2123 ms | **0.36 ms** | 0.60 ms — cljw 1.7× faster |
| `rest` (vector) | 2253 ms | **0.39 ms** | 0.87 ms — cljw 2.2× faster |
| `next` (vector) | 2164 ms | **0.38 ms** | 0.99 ms — cljw 2.6× faster |

`(seq v)` built an eager `PersistentList` copy — one allocation and one trie
descent per element, per call. Clojure never copies: its seq over a vector is a
**view** holding `(vector, index)`. cljw now does the same, so all three are
O(1), and `nth` on such a seq is O(1) too (Clojure walks there).

This one mattered out of proportion to any single benchmark, because `seq` /
`rest` / `next` are what every hand-written `loop`/`recur` walk and every
library seq walk uses. It did not show up as a benchmark regression precisely
because the *idiomatic* paths — `reduce`, `doseq`, `into` — already bypassed
`seq` with index-walk and chunk-drain fast paths.

## What is still slow

| op | clj 1.12.4 | cljw | |
|---|---|---|---|
| **`subvec`** | **1.06 ms** | **9215 ms** | **~7500× slower** |

`subvec` eagerly copies where Clojure returns a `SubVector` sharing the parent's
root and tail. It is the last measured catastrophic gap, and the fix is a real
design decision rather than a missing call: cljw's heap-tag space is a fixed
64-slot census, so a new vector *representation* has to either spend one of the
reserved names or thread an offset through every existing vector operation.
Until it lands, prefer `(into [] (take n (drop k v)))`-style slicing only where
you would have paid for a copy anyway, and avoid `subvec` in a loop.

## What this means if you are choosing cljw

- **Data-structure-heavy code is fine.** Persistent vectors, maps and sets
  perform comparably to the JVM's, sometimes better.
- **Tight numeric loops are not cljw's strength yet.** The interpreter overhead
  dominates, and that is a compiler problem, not a library one.
- **Startup is where cljw wins outright** — milliseconds against the JVM's
  ~1–2 s, which is the whole point for CLI tools, scripts and serverless. See
  [`binary_size.md`](./binary_size.md) for the size side of the same story.
- **If you hit something pathologically slow, it is probably a bug.** Every gap
  on this page was, and each was found by running a probe rather than by reading
  code. `.dev/bench/` has the harness; an issue with a reproducing form is
  useful.
