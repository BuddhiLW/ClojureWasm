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
| **`list` `count`** | **0.18** | **481** | **2711× slower** |

The headline is NOT "cljw is slow". The HAMT work is sound — cljw beats the JVM
on `nth`/`assoc`/`conj`/`get`/`dissoc`. Every loss is one of two specific
mistakes, and neither is a data-structure problem:

1. **An abstraction-barrier violation** — the Clojure layer re-implements an
   operation the Zig barrier already provides correctly. `pop` was the pure
   case: `vector.zig::pop` is a faithful `PersistentVector.pop()`, and
   `core.clj` bypassed it with `(into [] (take (dec (count coll)) coll))`.
   Fixed as O-056; the fix added no algorithm, it just exposed the barrier op.

2. **Materialising where Clojure keeps a VIEW** — `seq`/`rest`/`next` on a
   vector build an eager `PersistentList` (`sequence.zig` `vectorToList` /
   `vectorTailAsList`) where Clojure returns a `ChunkedSeq` holding
   `(vector, index)`; `subvec` eagerly copies (D-044) where Clojure returns an
   `APersistentVector$SubVector` sharing the parent's root and tail.

## Ranked remaining work

| # | Fix | Kind | Unblocks |
|---|---|---|---|
| 1 | Chunked vector-seq VIEW (vector + index) behind the existing seq protocol | view, not algorithm | `seq` + `rest` + `next` in one change — the systemic one, since these are what every hand-written seq walk uses |
| 2 | `SubVector` view (D-044 — "land when the benefit is measurable"; it is now measured: 7480×) | view | `subvec`, and every `drop`/`take`-style slice built on it |
| 3 | Cached count on `PersistentList` | one field | `count` on a list |

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
