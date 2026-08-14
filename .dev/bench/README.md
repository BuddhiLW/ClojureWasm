# Collection-algorithm parity bench (cljw vs clj)

Motivating question (user, 2026-08-13): *for performance, should cljw reimplement
the same immutable algorithms core Clojure does?*

Answered by measurement rather than by reading either implementation, per the
"measure the provider before you abstract it" principle: the same probe form is
evaluated in a cljw nREPL and a JVM Clojure 1.12.4 nREPL on the same box.

## Method

`scaling_form.edn` — run a FIXED number of operations (2000, after 300 warmup
iterations so the JVM has JIT-compiled) against collections of growing size
`[1000 4000 16000]`. Flat wall-clock across sizes means the operation is
O(1)/O(log n) per call; time growing with the size factor means O(n).

Run it in both REPLs:

    code cider spawn repl_type=cljw name=perf-cljw project_dir=<repo>
    code cider spawn repl_type=clj  name=perf-clj  project_dir=<repo>
    code cider eval  session_name=... code=<contents of scaling_form.edn, one line>

`scaling.clj` / `traversal.clj` are the standalone script forms (`cljw
.dev/bench/scaling.clj`) — same probes, human-readable output, plus a
whole-collection traversal probe that checks for accidental O(n²).

## Result, 2026-08-13 (ms per 2000 ops at n=16000, ReleaseSafe vs clj 1.12.4)

| op | clj | cljw | verdict |
|---|---|---|---|
| `nth` (mid) | 0.31 | 0.26 | cljw faster |
| `assoc` (mid) | 5.17 | 1.20 | cljw faster |
| `conj` | 2.79 | 2.29 | comparable |
| `map` `get` | 0.58 | 0.42 | cljw faster |
| `map` `assoc` | 3.38 | 2.26 | cljw faster |
| `map` `dissoc` | 5.09 | 1.15 | cljw faster |
| `list` `conj` | 0.36 | 0.43 | comparable |
| **`pop`** | **1.93** | **8278** | **4288× slower → FIXED (O-056), now 2.47** |
| **`subvec`** | **1.06** | **7929** | **7480× slower** |
| **`seq`** | **0.60** | **2123** | **3549× slower** |
| **`rest`** | **0.87** | **2253** | **2576× slower** |
| **`next`** | **0.99** | **2164** | **2184× slower** |
| **`list` `count`** | **0.18** | **481** | **2711× slower → FIXED (O-057), now 0.19** |

### Correction: the small deltas above are NOT reliable

The first table's "cljw faster" verdicts on the sub-microsecond ops were an
artefact of too few reps and no baseline. Re-measured best-of-7 over 20000 ops
with an empty-loop baseline subtracted (n=16000):

| per 20000 ops | clj | cljw | |
|---|---|---|---|
| **empty `dotimes`** | **0.043** | **0.900** | **clj 21× faster** |
| `nth` | 0.373 | 0.879 | cljw 2.4× |
| `assoc` | 49.38 | 21.43 | cljw 2.3× |
| map `assoc` | 73.93 | 18.77 | cljw 3.9× |
| map `dissoc` | 2.62 | 8.15 | clj 3.1× |
| `conj` | 1.75 | 7.62 | clj 4.4× |

Two separate things, which the first table conflated:

- **Interpretation speed: the JVM is far ahead.** An empty loop costs cljw 45ns
  per iteration against the JVM's 2.2ns. That is not Zig losing to Java — it is
  an *interpreter* (tree-walk / VM) losing to a *JIT* that has compiled the loop
  to native code with the induction variable in a register. Nothing about the
  collection work changes it; only a compiler would.
- **The persistent structures themselves: same league, trading wins.** cljw is
  ahead on `nth` and on both `assoc`es (its bump-allocating GC makes the
  path-copy cheaper); the JVM is ahead on `conj` and `dissoc`. No 1000× effects
  in either direction once the algorithms match.

So: do not read this bench as "Zig beats the JVM". Read it as "the data
structures are sound, and every catastrophic number below is algorithmic".

### The catastrophic numbers are algorithmic, not linguistic

Every loss is one of two specific mistakes, and neither is a data-structure
problem:

1. **An abstraction-barrier violation** — the Clojure layer re-implements an
   operation the Zig barrier already provides correctly. `pop` was the pure
   case: `vector.zig::pop` is a faithful `PersistentVector.pop()`, and
   `core.clj` bypassed it with `(into [] (take (dec (count coll)) coll))`.
   Fixed as O-056; the fix added no algorithm, it just exposed the barrier op.

   `list count` was the same class with a twist: the barrier op existed
   (`Cons.count`, O(1)) but was DISTRUSTED, because a `.list` cell can head a
   mixed chain (`(cons x (map …))`) where the stored number is the `.list`
   prefix length, not the total. Fixed as O-057 by making the field
   self-validating — a `COUNT_UNKNOWN` sentinel marks exactly the chains that
   must still walk — rather than by waiting for the D-178 `.list`/`.cons` tag
   split the old comment deferred to. When a barrier value is right *most* of
   the time, say WHICH times in the value itself; a blanket distrust throws
   the fast path away for every caller.

2. **Materialising where Clojure keeps a VIEW** — `seq`/`rest`/`next` on a
   vector build an eager `PersistentList` (`sequence.zig` `vectorToList` /
   `vectorTailAsList`) where Clojure returns a `ChunkedSeq` holding
   `(vector, index)`; `subvec` eagerly copies (D-044) where Clojure returns an
   `APersistentVector$SubVector` sharing the parent's root and tail.

## Ranked remaining work

| # | Fix | Kind | Unblocks |
|---|---|---|---|
| 1 | `SubVector` view (D-044 — "land when the benefit is measurable"; it is now measured: 7480×) | view | `subvec`, every `drop`/`take`-style slice built on it — **and (2), see below** |
| 2 | Chunked vector-seq VIEW behind the existing seq protocol | view, not algorithm | `seq` + `rest` + `next` in one change — the systemic one, since these are what every hand-written seq walk uses |
| ~~3~~ | ~~Cached count on `PersistentList`~~ | ~~one field~~ | **DONE — O-057. The field already existed; what was missing was a way to say when it is exact.** |

**(1) now ranks above (2) because it is (2)'s enabler.** `.range` already shows
the shape a chunked seq takes here without costing a Tag: `range.seqChunk`
materialises ≤32 elements into a `chunked_cons` whose `next` is *a smaller
`.range`* — a self-similar producer value, not a closure and not a new
representation. The vector analogue of "a smaller range" is "the vector minus
its first 32 elements", which is exactly a `SubVector` view. Land (1) and (2)
is `chunked_cons{v[k..k+32], subvec(v, k+32)}`, reusing the one chunk
mechanism (F-011) with no new seq type at all.

Note the constraint that makes this the attractive route: `heap_tag.zig`'s
census is closed at 64 slots, and its own doc says spending one of the 9
`unallocated` names is a user decision, not an implementation detail. A design
that needs no new Tag sidesteps that question entirely. `SubVector` itself
still has to answer it — either a repurposed slot, or a `start: u32` inside
`Vector`'s existing `_pad: [6]u8` (no struct growth, but then EVERY vector op
must honour the offset, which is the real cost and the thing to weigh).

(1) and (2) are the same shape and should follow OCP: add a new seq/vector
REPRESENTATION that satisfies the existing protocol, so no consumer changes —
not an `if` branch at each call site. That is also what keeps D-044's "new Tag
slot + polymorphic dispatch" cost honest.

Caveat on (1): `reduce` / `doseq` / `into` over a vector are already fast — the
index-walk and chunk-drain fast paths (O-002, O-004, O-032) bypass `seq`
entirely, and `traversal.clj` confirms they stay linear. So the eager `seq`
hurts hand-written `loop`/`recur` walks and library code, not the idiomatic
core paths. That is why it is ranked by breadth rather than by any single
benchmark regression.
