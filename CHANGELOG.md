# Changelog

All notable changes to ClojureWasm are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows
[SemVer](https://semver.org/). SemVer compatibility guarantees start at the
first stable `1.0.0` tag; pre-1.0 `alpha` / `rc` tags may still change surfaces.

## [Unreleased]

### Added

- **`cljw.net/listen` — a cljw process can now SERVE, not only dial.**
  `cljw.net` exposed `connect` and nothing else, so a cljw program could reach
  out and never answer: no RPC endpoint, no socket server, no accepting
  anything. The `.listen`/`.accept` pair it needed has been in
  `src/app/nrepl.zig` the whole time (cljw runs an nREPL server); this lifts it
  to a Clojure-facing surface.

  ```clojure
  (let [srv  (cljw.net/listen "127.0.0.1" 0)   ; 0 = ask the OS
        port (.port srv)                        ; ...and find out what it gave
        sock (.accept srv)]                     ; blocks until a peer arrives
    (.read sock (byte-array 1024))
    (.close sock)
    (.close srv))
  ```

  `.accept` answers a socket built on the **same** descriptor `connect`
  produces, so `.read` / `.write` / `.close` gained no new arm — a new
  *producer* of an existing representation rather than a second representation
  every reader would have to tell apart.

  `.port` reports the BOUND port, which is the only thing that makes `(listen h
  0)` usable. `.close` is idempotent and closes the listener alone: sockets it
  already handed out stay open, matching a JVM `ServerSocket`.

  A hostname is rejected rather than resolved. You bind an interface this host
  already owns, so there is nothing to look up and a name is a caller mistake.

- **`cljw.net/connect-unix` and `cljw.net/listen-unix` — UNIX domain sockets.**
  A unix socket needs no port to allocate or collide on, and the filesystem
  already answers who may connect, which is why local RPC endpoints prefer one.

  ```clojure
  (let [srv  (cljw.net/listen-unix "/tmp/app.sock")
        sock (.accept srv)]
    (.read sock (byte-array 1024))
    (.close sock)
    (.close srv))
  ```

  `UnixAddress.listen` / `.connect` answer the **same** `Server` / `Stream`
  types the IP pair does, so these reuse both carriers, both descriptors, both
  method tables and both finalisers unchanged — a unix socket is a different
  *address*, not a different representation. `.accept` / `.read` / `.write` /
  `.close` are the same functions the TCP side uses.

  Two behaviours are deliberate, and pinned by the e2e because they can look
  like bugs. `.port` on a unix server answers **0** — a unix socket genuinely
  has no port, and 0 is honest where a fabricated value would not be. And a
  leftover socket file from a dead process is **not unlinked for you**: the
  path may still belong to a live server, and deleting another process's socket
  is the caller's decision, not the runtime's.

  The 108-byte path cap is the OS's rather than the filesystem's — easy to
  exceed with an ordinary temp path — so it is reported as a clear argument
  error instead of an opaque bind failure.

### Fixed

- **`(atom v :meta m)` / `ref` / `agent` reject a non-map `:meta`.** clj's
  `setup-reference` casts a `:meta` constructor option to `IPersistentMap`, so a
  number, set, or vector `:meta` throws `ClassCastException` — but cljw silently
  accepted it (e.g. `(meta (atom 1 :meta 5))` returned `5`). All three reference
  constructors now reject a non-nil, non-map `:meta` through one shared guard
  (`iref.requireMetaMap`).

- **`(contains? array i)` tests index validity instead of throwing.** A Java
  array is Indexed, so clj's `contains?` answers `true`/`false` for an integer
  key by bounds — but cljw raised `No implementation of method
  '-contains-key?' on protocol 'Associative' for type 'array'` for every key.
  It now matches: an integer key reports whether the index is in range. A
  non-integer key still raises (an array is not associative, so — unlike a
  vector's miss, which is `false` — clj does not treat it as merely absent).

- **`(empty x)` returns `nil` for a non-collection instead of throwing.** clj's
  `empty` answers `nil` for anything that is not an `IPersistentCollection` — a
  number, char, keyword, symbol, boolean, ratio, BigInt, or a Java array — but
  cljw raised `No implementation of method '-empty' on protocol
  'IPersistentCollection' for type 'Long'`. It now matches clj: every
  non-collection value yields `nil`. A `deftype`/`reify` that declares itself a
  collection still raises if it left `-empty` unwired — a missing impl there is a
  developer error, not a silent `nil`.

- **`(range …)` over Long bounds past ±2^47 no longer errors — a range spans
  the full Long domain.** cljw stores an integer past its ±2^47 inline window as
  a heap Long, and a recent fix taught `int?` to recognise those; that routed
  `(range (bit-shift-left 1 55) (+ 4 (bit-shift-left 1 55)))` to the compact-range
  fast path, whose guard accepted only inline integers — so it raised `-range:
  expected integer, got big_int` where clj yields the finite Long range.

  A compact range is now a full i64-domain value, like a JVM `LongRange`: it
  accepts heap-Long bounds, and every element it hands out — through `first`,
  `nth`, `reduce`, `count`, a chunked `map`/`seq` walk, or print — boxes a value
  past ±2^47 as a heap Long (exact, class `Long`), never a float. A range whose
  elements cross the ±2^47 boundary mid-sequence is exact throughout. Every
  projection of the range to a value now flows through one boxing point, so
  there is no path left that can still spill an element or the count to a float.

- **`assocEx` is wired on a `deftype`/`reify` `clojure.lang.IPersistentMap`
  section.** clj's `IPersistentMap` declares `assocEx` — assoc that throws when
  the key is already present — so a type implementing the interface faithfully
  declares it. cljw's remap table had no row for the name, and an unwired
  `clojure.lang.*` method is a LOAD-time raise, so one unrecognised name took
  down the entire type, and with it the namespace, and with it every namespace
  requiring it.

  Found against [replikativ/boring][boring]: `boring.data`'s `UnknownRecord`
  declares `assocEx` between `assoc` and `without`, and the namespace would not
  load at all. The declaring type's own body supplies the behaviour, so
  registering the method is all cljw owes it; `IPersistentMap` gains the
  matching `-assoc-ex` protocol method plus the identity remap row every
  member needs so a cljw-form `extend-type` section passes through unrewritten.

  `(.assocEx native-map k v)` stays deliberately unwired. There is no
  `clojure.core` fn with `assocEx`'s semantics, and mapping it to `assoc` would
  answer a *different question silently* — the failure class F-002 rejects. It
  therefore still raises, which is the honest answer until a caller justifies a
  real primitive.

[boring]: https://github.com/replikativ/boring

## [1.11.0] - 2026-08-22

### Added

- **cljw compiles and runs on wasm32-wasi** — `zig build -Dtarget=wasm32-wasi` produces a module that runs full Clojure under wasmtime, Chicory (in-JVM) and zwasm. The precise root set already covers the vm backend, so no GC rewrite was needed. (ADR-0193.)

- **A guest's linear memory is readable and writable from Clojure** —
  `(wasm/mem-size m)`, `(wasm/mem-read m :f64 offset n)` and
  `(wasm/mem-write! m :f64 offset data)`. `wasm/call` marshals scalars, which
  reaches every guest whose whole interface fits in numbers; the dominant
  convention for a *numeric* guest does not — it passes an array as a
  `(pointer, length)` pair into linear memory, so the host has to fill the
  buffer before the call and read it after. Until now `wasm/call` could pass
  the pointer and nothing could put anything at the other end of it.

  Element types are the nine wasm widths (`:i8 :u8 :i16 :u16 :i32 :u32 :i64
  :f32 :f64`), offsets are in bytes, encoding is little-endian (the wasm memory
  model), and unaligned access works — a `(ptr,len)` ABI hands the host
  whatever offset the guest's allocator produced. `:i64` round-trips exactly
  past the immediate-integer window rather than degrading to a float, and every
  bad offset, count or element is a catchable exception naming the fn and the
  element index, never a host panic. (ADR-0192.)

## [1.10.19] - 2026-08-22

### Performance

- **`(seq s)` over a string is now an O(1)-per-step byte-offset view**
  (the JVM `StringSeq` model), replacing the eager n-cell codepoint cons
  chain. The old path asked `codepointAt(s, i)` per element, restarting a
  UTF-8 walk from byte 0 each time — **O(n²)** overall (measured 89,910 ms
  for a 146,670-character string; downstream, bb-mcp paid ~79 s/boot asking
  `(seq value)` as a truthiness test on a large nREPL response). Now O(n):
  `first` decodes in place at the byte offset, `rest` advances by the width
  read, `count` is a single forward scan. A `StringSeq` is an ordinary seq of
  characters — `seq?`, `sequential?`, `=`/`hash` with the equal char list
  **and** char vector (incl. as a map key), UTF-8-correct `count`/`nth`.
  (O-060, D-179; `.string_seq` heap tag — a day-1 F-004 reservation, no slot
  spent.)

## [1.10.18] - 2026-08-22

### Performance

- **`subvec` is now an O(1) shared-structure view** (the JVM
  `APersistentVector$SubVector` model), replacing the eager `(into [] (take …
  (drop …)))` rebuild — the last catastrophic collection gap. Measured 2000
  slices on a 16,000-element vector: **9215 ms → 0.77 ms (~11,967×)**, now at
  parity with Clojure/JVM. A subvec is a first-class `IPersistentVector`
  (`vector?`, `=`/`hash`/`compare` with an equal vector, `nth`/`conj`/`assoc`/
  `pop`/`peek`/`seq`/`rseq`/`reduce`, metadata, nested-subvec flattening); its
  `conj`/`assoc`/`pop` share structure with the parent instead of copying.
  (O-059, D-583/D-044; new `.sub_vector` heap tag from the F-004 `box` slot.)

## [1.10.16] - 2026-08-21

### Fixed

- **clojure.core parity — comparators, `min`/`max`, `min-key`/`max-key`,
  `some-fn`/`every-pred`, `seqable?`** (from the clojure-test-suite drain):
  - `<` `>` `<=` `>=` `==` are `([x] true)` at 1-arity and no longer inspect the
    operand, so `(> "abc")` and `(== nil)` return `true` instead of raising a
    type error.
  - `min`/`max` propagate NaN like JVM Clojure: any NaN operand yields `##NaN`
    (`(max 1 ##NaN)` => `##NaN`) rather than dropping it.
  - `min-key`/`max-key` keep the later element on a tie and reproduce clj's
    IEEE-NaN behaviour.
  - `some-fn`/`every-pred` apply each predicate to each argument
    (`((some-fn even?) 1 2)` is `true`), where before they passed all arguments
    to one predicate and raised an arity error.
  - `seqable?` is now true for arrays.

## [1.10.14] - 2026-08-21

### Added

- **`cljw.test` — a source-path test runner.** `cljw -m cljw.test [dirs…]`
  discovers every `*_test.clj[c]` under the given roots (defaulting to the
  classpath, then `test/`), requires each namespace, runs it, and prints one
  totals line: `N namespaces, N tests, N assertions, N failures, N errors,
  N unloadable.` A namespace that throws while loading ran no assertions at
  all, so it is counted as **`:unloadable`** rather than folded into the error
  count — an assertion total that includes tests which never ran is a lie
  about coverage, and it is exactly the lie a compliance campaign cannot
  afford. The exit code is non-zero if anything failed, errored, **or** failed
  to load.

- **`java.class.path`** is answered by `System/getProperty` and appears in
  `System/getProperties`, joined from the runtime's load paths with the
  platform separator. `cljw.test` uses it to default its roots.

- **`clojure.test` gains the API that clj's `:test` model unlocks**:
  `test-ns`, `test-vars`, `test-all-vars`, `test-var`, `run-test`,
  `run-test-var`, `with-test`, `set-test`, `deftest-`, `successful?`,
  `*load-tests*`, `assert-predicate`, `assert-any`,
  `get-possibly-unbound-var`, plus `assert-expr` methods for `instance?` and
  `:always-fail`. `run-all-tests` now walks `all-ns` and accepts a regex.

### Fixed

- **`clojure.edn/read-string` and `clojure.core/read-string` now differ on
  empty input, matching clj.** `clojure.edn/read-string`'s 1-arity defaults
  `{:eof nil}`, so empty / whitespace-only / comment-only input returns `nil`
  (its docstring: "Returns nil when s is nil or empty"); `clojure.core/read-string`
  throws `EOF while reading` on the same input. cljw previously threw for both —
  the shared body had been reasoned about from `core`'s behaviour and never run
  against `edn`. An explicit `:eof` opt still overrides for either reader.

- **`*print-level*` was off by one for every record.** The depth bookkeeping
  keyed off `Value.tag()`, and `.typed_instance` is not a collection tag — but
  a record and a deftype declaring `clojure.lang.IPersistentMap` both render as
  maps. `(binding [*print-level* 1] (pr-str (R. {:x 1})))` gave
  `#user.R{:a {:x 1}}` where clj gives `#user.R{:a #}`, and at the cut a record
  now renders `#user.R#` — the tag prints outside the cut and the map body
  inside it, as clj does. A deftype carries no tag, so it cuts to `#` whole.

- **A `print-method` override rendered against the PREVIOUS print's limits.**
  `printConsult` snapshotted `*print-length*` / `*print-level*` / `*print-meta*`
  / `*print-namespace-maps*` / `*print-readably*` only on the path where no
  override fired. So `(binding [*print-length* 2] (pr-str (Box. [1 2 3 4 5])))`
  printed `Box<[1 2 3 4 5]>` instead of clj's `Box<[1 2 ...]>` — and because the
  snapshot is thread-local, a print's output depended on what had been printed
  before it in the process. The same expression could render truncated or
  untruncated according to print history, so a test could pass alone and fail in
  a suite. Only a value whose own type carried the override was affected; the
  same value nested one level deeper was already correct.

- **An IPersistentMap-declaring deftype inside a `print-method` override**
  rendered `#Pm[{:a 1}]` instead of clj's `{:a 1}`, because the override path
  never armed the context the map-style render needs.

- **A macro that `throw`s while expanding now surfaces the exception it
  threw** — catchable, with its message, its `ex-data` and its host class
  intact. It used to become `Internal error: macro callFn raised foreign
  error`, because `narrowCallFnError` folded `error.ThrownValue` into
  `InternalError`. Argument validation in a macro — what `clojure.core`'s own
  `assert-args` does, and what every macro rejecting a malformed binding
  vector does — could therefore not tell its caller what was wrong.

- **`clojure.test` reported something other than what ran**, in three ways
  that all read as green (ADR-0191):

  - `(run-tests *ns*)` — the call clj's own 0-arity makes — printed
    `Ran 0 tests, 0 failures` because the registry was keyed by namespace
    *symbol* and a `Namespace` object matched nothing. `run-tests` /
    `test-ns` / `test-all-vars` now accept a symbol, a string or a
    `Namespace`, and an unknown namespace raises instead of passing.
  - Re-evaluating a `deftest` (any reload) registered the var a second time,
    so one test counted as two. Registration is idempotent now.
  - `(are [x y] (= x y) 1 1 2)` silently dropped the trailing partial group
    and passed; it now throws `IllegalArgumentException`, as clj does.

- **`use-fixtures` replaces rather than appends**, and stores into the
  namespace's own metadata where clj keeps it — so reloading a namespace no
  longer runs its fixtures once more per reload.

- **`report`'s `:default` method prints an unrecognised event** instead of
  swallowing it, which is what makes the explicit no-op methods for the
  per-var events load-bearing rather than decorative.

### Internal

- **CI's Zig build cache now actually caches.** The cache key was
  `hashFiles('build.zig.zon', 'build.zig')` — files that change a few times a
  year — so it hit on nearly every run, and `actions/cache` only *writes* an
  entry when its key *misses*. The restored `.zig-cache` was frozen at whatever
  the first run with that `build.zig` produced; every run since rebuilt
  everything that had changed after that snapshot and discarded the result,
  while the step reported a cache hit. Measured on the Linux leg:
  `zig_build_test_vm` 375 s and `zig_build_test_tree_walk` 371 s — 50% of a
  1491 s gate — against ~5 s each warm. The key now carries the run id with
  prefix `restore-keys`, and restore/save are split with `if: always()` so a
  **failed** run still saves its build products, which is precisely when the
  next run needs them. `scripts/prune_zig_cache.sh` bounds the saved tree so
  "always save" cannot become unbounded growth.

- **`scripts/run_gate.sh` no longer kills healthy gates.** Its timeout defaulted
  to 900 s, sized against a "~350 s serial gate"; the suite has since grown to
  1009 s (macOS) / 1491 s (Linux) cold, so the default could not complete a full
  gate on any host. The kill presented as a log that simply stopped — no summary
  line, nothing to distinguish it from a pass, which is the failure mode the
  script's own header warns about. Default is now 2700 s, and a timeout prints
  an explicit "KILLED, not failed" verdict instead of exiting quietly.

### Changed

- **`clojure.test` adopts clj's var model** (ADR-0191): a test's body lives in
  the var's `:test` metadata and the var's value is a thunk routing through
  `test-var`. `*test-registry*` is demoted to a pure definition-order index.
  This is what makes cljw legible to any runner that enumerates `ns-interns`
  filtering on `:test`, and what makes `(alter-meta! #'f assoc :test …)` work.

- **The printer's VM re-entry is an explicit parameter.** `printValue` took
  `(w, v)` — the signature of something that cannot evaluate — while two
  file-private thread-locals let it call arbitrary user Clojure and dispatch
  protocols. Both are gone, replaced by a `?Ports` threaded through the
  recursion: `null` at a caller that cannot evaluate, rt/env at one that can.
  The three print fixes above were all one shape — state armed at one entry
  point and read from another — which a parameter makes impossible.

- **Printing no longer realizes what `*print-level*` will cut**, and no longer
  rebuilds a vector that holds nothing lazy. A depth-18 tree at
  `*print-level* 1` renders in 0.10 ms where it took 6668 ms (50 prints); a
  20 000-element vector printed 200 times takes 189 ms where it took 1167 ms.
  No output changes.

## [1.10.6] - 2026-08-14

### Internal

- **The release bump also stamps this file.** `preflight` renames
  `## [Unreleased]` to `## [X.Y.Z] - date` and opens a fresh one in the SAME
  `chore(release)` commit that rewrites `build.zig.zon`, so the changelog and
  the tag are written together and cannot drift
  (`.github/stamp_changelog.py`).

  A version whose `[Unreleased]` body is **empty is not stamped**: patches now
  cut themselves on every source push, and a release nobody wrote up must not
  mint an empty version heading. CHANGELOG.md is deliberately absent from the
  workflow's relevance paths for the same reason build.zig.zon is — the bump
  commit touches both, and counting them would make each release mint the next.

  `1.10.3`–`1.10.5` were stamped by hand: they shipped between the arrival of
  automatic patch releases and this, so their entries had accumulated under a
  single `[Unreleased]` heading with no version to attach to.

## [1.10.5] - 2026-08-14

### Fixed

- **Dropped a dead `std` import from `Future.zig`.** Lint-only; the module's
  behaviour is unchanged.

## [1.10.4] - 2026-08-14

### Changed

- **`(seq v)` / `(rest v)` / `(next v)` on a vector are now a VIEW, not a copy.**
  They used to build an eager `PersistentList` — n cell allocations and n trie
  descents per call. They now return an `ArraySeq` holding `(vector, index)`,
  which is what Clojure does (`PersistentVector$ChunkedSeq`). All three drop
  from O(n) to O(1): measured over a 16000-element vector, `seq` 2123 → 0.36 ms,
  `rest` 2253 → 0.39 ms, `next` 2164 → 0.38 ms per 2000 ops — from 2184-3549×
  slower than JVM Clojure 1.12.4 to 1.7-2.6× faster. `nth` on such a seq is now
  O(1) too, where clj still walks. See `O-058` in `.dev/optimizations.md`.

  Everything observable is unchanged — it prints as a seq, is `=` to the list
  and the vector with the same elements, hashes with them, and works as a map
  key — with ONE exception: **`(class (seq [1 2 3]))` now answers `ArraySeq`
  where it used to answer `PersistentList`.** Neither matches the JVM's
  `PersistentVector$ChunkedSeq`; code that branches on that class name was
  already non-portable, and `seq?` / `sequential?` / `coll?` / `counted?` are
  unaffected.

  This closes item 2 of `.dev/bench/README.md`'s ranked list — which that file
  had wrongly recorded as blocked on item 1 (`SubVector`). See the correction
  there: `next` of a seq is a seq, so the vector-seq needed `(vector, index)`
  and never needed a smaller vector. `subvec` remains eager (D-044).

## [1.10.3] - 2026-08-14

### Added

- **`java.util.concurrent.Future`'s method names on cljw's own futures.** `.get`
  (`[]` / `[timeout unit]`), `.isDone`, `.isCancelled` and `.cancel`
  (`[]` / `[mayInterruptIfRunning]`) now resolve on the value `(future …)`
  returns — which already answered `Future` to `class` and already had every
  semantic behind `deref` / `realized?` / `future-cancel` / `future-cancelled?`.
  Each method delegates to that existing primitive, so `.get` and `@` cannot
  disagree: a cancelled future still throws `CancellationException` and a failed
  one still re-raises the worker's marshalled error (ADR-0120) rather than a
  second set of answers invented for the Java spelling.

  The timed arity is the one deliberate departure from cljw's own `deref`:
  `(.get f timeout unit)` **throws `java.util.concurrent.TimeoutException`**
  where the 3-arity `deref` returns a caller-supplied default, because code that
  catches TimeoutException to decide whether to cancel would read a returned
  default as success. The eval budget still bounds the wait, and a future still
  pending at the budget's deadline reports the budget instead.

  `Future` also joins the reify-able host interfaces (both the qualified and the
  bare post-`:import` spelling), for libraries that synthesise an
  already-completed Future rather than minting a worker.

  `mayInterruptIfRunning` is accepted and ignored (AD-065): cljw's cancellation
  is cooperative, so there is no queue-vs-running distinction to honour.

- **`java.util.concurrent.RejectedExecutionException` is a known exception
  type**, so `(catch RejectedExecutionException …)` compiles. A `RuntimeException`
  like on the JVM. Caught-but-never-thrown for now, joining `InterruptedException`
  / `TimeoutException` / `ExecutionException` in that family — cljw has no pool
  that rejects a submission yet.

  Both found by driving [hive-weave](https://github.com/hive-agi/hive-weave)
  through cljw: `hive-weave.pool` — a bounded pool with caller-runs fallback,
  binding-conveying `submit!` and a synthetic Future for work that ran on the
  caller thread — now loads on it.

- **`java.util.concurrent.Semaphore`.** Permits live in one atomic counter and
  move by CAS: `<init>` (`n` / `n fair?`), `.acquire` (`[n]`), `.tryAcquire`
  (`[n]`, `[timeout unit]`, `[n timeout unit]`), `.release` (`[n]`),
  `.availablePermits`, `.drainPermits`, `.getQueueLength`, `.hasQueuedThreads`,
  `.isFair`. A parked caller polls through the budgeted sleep `Thread/sleep`
  owns, so `future-cancel` and the eval budget cut the wait short instead of
  pinning a worker for the whole timeout. Fairness is recorded but does not
  order acquisition (AD-061). Found by driving
  [hive-weave](https://github.com/hive-agi/hive-weave)'s admission gates
  through cljw: `hive-weave.gate` and `hive-weave.budget` — permit gating,
  cost-based budget admission, saturation timeouts and stats — now run on it.

- **`java.util.concurrent.atomic.{AtomicLong,AtomicInteger,AtomicBoolean}`.**
  One CAS-moved word each: `<init>` (`[v]`), `.get`, `.set`, `.lazySet`,
  `.getAndSet`, `.compareAndSet` / `.weakCompareAndSet`, plus the numeric
  `.incrementAndGet`, `.decrementAndGet`, `.getAndIncrement`,
  `.getAndDecrement`, `.addAndGet`, `.getAndAdd`, `.longValue` / `.intValue`.
  Exact under cljw's real OS threads — four threads racing 500 increments
  apiece land 2000, not fewer. AtomicInteger does not truncate to 32 bits
  (AD-062).

- **`java.util.concurrent.TimeoutException` is constructible.** `catch` already
  resolved the class (`host_class.zig` carries the FQCN mapping and the
  `TimeoutException < Exception` edge); the surface adds `(TimeoutException.)`
  / `(TimeoutException. msg)`, which is what a library needs to raise one.

- **`java.lang.Runtime` reports memory.** `.totalMemory`, `.freeMemory` and
  `.maxMemory` answer from cljw's own mark-sweep accounting and from the
  `CLJW_EVAL_MAX_HEAP_MB` ceiling (ADR-0125) rather than from a fabricated
  constant, so a heap-pressure monitor either reads real numbers or correctly
  reads "no ceiling" (AD-063).

- **`java.util.concurrent.LinkedBlockingQueue`.** A bounded FIFO backed by a
  cljw vector plus a head index: `<init>` (`[capacity]`, unbounded without),
  `.offer` (`[x]`, `[x timeout unit]`), `.put`, `.poll` (`[]`,
  `[timeout unit]`), `.take`, `.peek`, `.size`, `.isEmpty`,
  `.remainingCapacity`, `.remove` (`[]`, `[x]`), `.contains`, `.clear`,
  `.toArray`, `.drainTo`. The head index is what keeps it a queue —
  `vector.subvec` is an O(n) eager copy (D-044), so dequeuing by rebuilding
  from index 1 would make draining a work queue quadratic; the dead prefix is
  compacted only once it dominates the vector, which amortises to O(1). Blocking
  waits poll through the budgeted sleep `Thread/sleep` owns, and the per-instance
  spin lock is never held across one. `.drainTo` returns the drained elements
  rather than filling a mutable target cljw does not have (AD-064).

- **`ThreadFactory`, `Callable` and `Runnable` are reify-able.**
  `(reify java.util.concurrent.ThreadFactory (newThread [_ r] …))` — and the
  bare spelling after `:import` — now loads and dispatches, so a library can
  hand a pool its own worker-minting policy. They join the host-interface
  closed set (`data/host_interfaces.yaml`, ADR-0102) rather than becoming
  native classes, because `reify` accepts only a protocol Var or a marker name
  and rejects a class value outright.

### Fixed

- **Host surfaces returning a large integer no longer hand back a Double.**
  `Value.initInteger` silently converts an argument outside the NaN-boxed i48
  range to an `f64`; an exact Long past that range must be heap-boxed through
  `big_int.allocFromI64(rt, i, .long)`. Caught on `(.maxMemory
  (Runtime/getRuntime))`, which returned `9.223372036854776E18` — a value that
  fails `(= … Long/MAX_VALUE)` and poisons integer arithmetic downstream.

## [1.10.2] - 2026-08-12

The fork's first runtime changes. Nearly all were found by driving
[malli](https://github.com/metosin/malli) through the
`test/conformance/verified_projects/` probe loop — malli is the first schema
library on the ladder, and the blockers it surfaced are general capabilities,
not malli accommodations (F-013). The last two entries under Added come from the
next rung, hive-contracts.

### Fixed

- **Macro expansion no longer drops symbol metadata.** `formToValue` attaches a
  symbol's `^meta` to the symbol Value (ADR-0110), but `valueToForm` rebuilt only
  `{ns, name}` — so every macro-produced form silently shed type hints,
  `^:private`, `^:const`, `^:dynamic`, and the `^:volatile-mutable` /
  `^:unsynchronized-mutable` deftype field markers. The visible symptom was a
  `deftype` whose method `set!`s a mutable field failing to resolve that field
  when, and only when, a macro emitted the form:

  ```clojure
  (defmacro mm [x] x)
  (mm (deftype E [^:volatile-mutable c]
        clojure.lang.IDeref (deref [_this] (do (set! c 9) c))))
  ;; was: Name error: Unable to resolve symbol: 'c'
  ```

  Writing the identical `deftype` literally worked, which is what isolated the
  fault to the Value↔Form round trip rather than to `deftype` or to `set!`.

### Added

- **`(instance? my.ns.MyProtocol x)`** — a protocol named by the interface name
  `defprotocol` generates on the JVM now resolves, including the package-segment
  demunge, so `my_ns.core.Q` finds the protocol in `my-ns.core`. Bare `P` and
  `alias/P` already worked; only the dotted form was unreachable.
- **`monitor-enter` / `monitor-exit`** in `clojure.core` — the two halves
  `locking` was already built from, on the same object monitor.
- **`clojure.lang.LazilyPersistentVector`** — `createOwning` / `create`.
- **`clojure.lang.PersistentArrayMap`** — `createWithCheck` (throws
  `IllegalArgumentException` on a duplicate key) / `create`.
- **`clojure.lang.Murmur3/hashLong`** and **`/hashInt`** — the implementations
  already existed in `hash.zig`; only the surface entries were missing.
- **`java.util.ArrayDeque`** — `push` / `pop` / `peek` / `poll` / `addFirst` /
  `addLast` / `removeFirst` / `removeLast` / `peekFirst` / `peekLast` / `size` /
  `isEmpty` / `clear`, plus `seq` and `count`.
- **`java.util.concurrent.TimeUnit`** — the seven constants as host-enum
  singletons (ADR-0161 registry), plus `.name` / `.toString` / `.toMillis` /
  `.toNanos`.
- **`java.lang.reflect.Array`** — `newInstance` / `getLength`. AD-031: the
  component-type argument is ignored, since cljw arrays are Object[] (ADR-0105).
- **`java.util.HashMap`** — the `(int, float)` sizing constructor and `.putAll`.
- **`java.util.AbstractList` / `java.util.Vector`** resolve as opaque classes
  (ADR-0109), so a library branching on them loads with that branch correctly
  dead. `java.util.ArrayList` declares `AbstractList` among its host supertypes,
  so `instance?` stays JVM-faithful for the one cljw does have values of.
- **`InterruptedException`, `TimeoutException`, `ExecutionException`** are now
  known catch classes. cljw has no interrupts and never throws them, so the
  clauses are dead by construction — but portable code guarding a bounded wait
  now loads instead of failing analysis.

The last two came from the next rung of the same loop,
[hive-contracts](https://gitea.hive-mcp.com). Both are reached through
`clojure.tools.reader`, which `taoensso.encore` — and so `timbre` — requires.

- **`clojure.lang.PersistentList/create`** — a list of a collection's elements,
  in order. `clojure.tools.reader.edn` calls it to build every list it reads.
- **`clojure.lang.LineNumberingPushbackReader`** resolves as an opaque class
  (ADR-0109), under its bare name as well as its FQCN since clj auto-imports
  `clojure.lang.*`. cljw readers are not instances of it, so `instance?` is
  uniformly false and `extend`ing it registers a branch nothing dispatches to —
  which is what `tools.reader` does with it.

### Internal

- `data/core_surface_extras.txt` regenerated, 104 → 106 names: `monitor-enter`
  and `monitor-exit` are a deliberate addition to clojure.core's extra public
  surface (AD-057). No name was removed.
- `scripts/check_core_surface.sh` pins `LC_ALL=C`. `sort`/`comm` were collating
  under the caller's locale, so the ledger regenerated to a different order on
  different machines — 16 lines of reordering noise around 2 real ones, in the
  one diff the gate exists to keep readable.
- `test/e2e/phase15_ns_import.sh` uses `java.util.ServiceLoader` as its
  unimplemented-class fixture. It had used `ArrayDeque`, which this release
  implements — the same way it previously used HashSet/TreeSet before D-431.
  `ServiceLoader` is classloader-driven, so a JVM-free runtime will not
  implement it and the fixture cannot go stale again.
- `test/e2e/phase16_gc_torture.sh` sets and clears environment variables with
  bash builtins instead of `env`, which is hijackable by a `~/.local/bin/env`
  on PATH.
- Two deprecated `std.mem` aliases replaced by their current names
  (`indexOfScalar` → `findScalar`, `indexOfAny` → `findAny`). Both are `pub
  const` aliases in 0.16 std, so the rename is behaviour-identical; the linter
  that rejects them runs only on the macOS gate leg, which is why they were
  reachable at all.
- The printer gains Layer 6/7 coverage (ADR-0186): a property asserting every
  `printFloat` output parses back to the same f64 — bit equality, so `0.0` and
  `-0.0` stay distinct — and golden snapshots for the HAMT print path above both
  promotion boundaries, for truncation at `*print-length*` 0, and for lazy seqs
  nested inside collections. The first mutation sweep of `print.zig` scored
  36.4%; these pin three of the survivors it named.
- `scripts/mutation/run.sh` takes `--oracle`. The kill oracle was hardcoded to
  `zig build test`, so a mutation in a rendering path could never be killed by
  the golden layer and every printing line scored as unconstrained. `unit`
  remains the default; `unit+golden` also renders the Layer 6 cases.

### Changed

- **The embedded Wasm engine is fetched from `zwasm/zwasm`.** zwasm moved out of
  the `clojurewasm` org into its own, where it continues under separate
  maintainership. `build.zig.zon` now names that location directly instead of
  relying on GitHub's transfer redirect, which is only an alias until something
  else claims the vacated name. The pin itself is unchanged — same tag (v2.5.0),
  same commit, same content hash. Merged from upstream, which made the same
  change in its own final release.
- **Release and CI workflows survive a re-run.** Both clear the Zig unpack
  target before `tar -x`, so a re-run cannot die on "Cannot open: File exists",
  and `release.yml`'s `gh release view || gh release create` race across the
  matrix legs is fixed: a failed create is accepted iff the release exists
  afterwards. Merged from upstream.

## [1.10.1] - 2026-08-12

**The first release of the maintained fork.** It carries no runtime change —
the binary is v1.10.0's, rebuilt — and exists to prove the fork's own release
path end to end: tag on `BuddhiLW/ClojureWasm`, artifacts built by this
repository's `release.yml`, and a `buddhilw/tap` formula pointing at them. A
release cut against a distribution path nobody has exercised is a guess; this
one makes the guess cheap to check.

### Changed

- **Maintenance moved to a fork.** Upstream
  [clojurewasm/ClojureWasm](https://github.com/clojurewasm/ClojureWasm)
  stopped at v1.10.0, its final release, and invited forks under EPL-2.0.
  Development continues in
  [BuddhiLW/ClojureWasm](https://github.com/BuddhiLW/ClojureWasm) from that
  exact tree — same gate, same ADR record, same release workflow. Nothing in
  the runtime changed. What moved: Issues and Pull Requests are open here
  (upstream disabled both, so contributions arrived as branches to
  cherry-pick), the Homebrew tap is now `buddhilw/tap`
  (`brew install buddhilw/tap/cljw`), and README / CONTRIBUTING / SECURITY /
  issue templates point at this repository. The `1.x` line continues from
  v1.10.0.

> **On the version number.** Upstream `clojurewasm/ClojureWasm` also tagged a
> `v1.10.1`, on the same day, from its own tree — its last release, carrying the
> zwasm repoint and its wind-down documentation. That tag names commit
> `8fa46d97`; this project's `v1.10.1` names `50b85214`, and it is the one
> `brew install buddhilw/tap/cljw` resolves. Since upstream's history is now
> merged here, both commits are reachable from this repository and the *name*
> `v1.10.1` no longer identifies one of them. Nothing after v1.10.1 collides:
> upstream cut no further releases, so this project's `1.x` continues
> unambiguously from v1.10.2.


## [1.10.0] - 2026-08-12

**The final release.** ClojureWasm is no longer maintained — a from-scratch
Clojure runtime turned out to be more than one person can sustain, and this
release exists so it stops at a working, fully-tested state rather than
mid-stream. The code stays up under EPL-2.0; fork it and build on it, no
permission needed. See the README for the full notice.

Everything here is a fix, and three of the four were found by @BuddhiLW,
who reported them with diagnoses and working branches — thank you. Each
one's *class* was then swept, which is where the rest of the fixes came
from. MINOR rather than PATCH because `repl` and `nrepl` gain a `-cp` /
`-A:alias` surface, and `cljw repl` now rejects unknown arguments it used
to ignore.

### Fixed

- **A top-level `(do …)` that requires before it uses now works in every
  entry point.** `(do (require '[clojure.string :as s]) (s/upper-case
  "ok"))` returned `"OK"` from `cljw -e` but raised `No namespace: 's'`
  over nREPL and in `cljw repl`, and failed to compile under `cljw build`:
  the top-level-`do` unroll, which analyses and evaluates each child in
  sequence so an earlier `require` or `defmacro` is visible to a later
  child, had only ever been wired into the script path. Reported,
  diagnosed and fixed for the REPL engine by @BuddhiLW (Discussion #14;
  commit cherry-picked with authorship preserved); the `cljw build` half
  was found by auditing the other callers. A new differential oracle
  (`test/e2e/entrypoint_eval_parity.sh`) now runs each program through
  `-e`, a script file, stdin, `repl`, `nrepl`, and `build`+run and
  requires all six to agree, so this class of entry-point divergence
  fails the gate instead of reaching users.

- **A set literal of 9+ elements no longer crashes macroexpansion**
  (segfault / index-out-of-bounds / bogus "cannot be re-analysed" —
  three faces of one misread). The analyzer decoded the set's backing
  map as if it were always array-backed; past the 8-element promotion
  boundary it read hash-map fields as array fields. Reported with a
  model bisection and fixed by @BuddhiLW (Discussion #12; commit
  cherry-picked with authorship preserved).
- **The same representation misread was audited tree-wide and three more
  live instances fixed**, all at the same 8→9 boundary: multimethod
  hierarchy (`derive`/`isa?`) dispatch silently vanished at the 9th
  `defmethod`; `cljw.http.client` rejected a 9-entry `:headers` map;
  `cljw.http.server` dropped all custom response headers past 8 entries.
  A structured-error-log context map of 9+ entries was also silently
  omitted from the EDN event. A new per-commit gate
  (`scripts/check_repr_decode.sh`) forbids the whole class: collection
  backing representations are now private to `src/runtime/collection/`.
- **`cljw nrepl` resolves the filesystem classpath** — it previously
  rejected `-cp`, ignored `$CLJW_PATH`, and never installed the
  filesystem require chain, so an editor session could not `require` a
  single namespace from the project it was started in. It now takes
  `[-cp <dirs>] [-A:alias…]` alongside `--port`, exactly like every
  other entry point. Diagnosed and fixed by @BuddhiLW (Discussion #13;
  commit cherry-picked with authorship preserved).
- **`cljw repl` no longer silently ignores trailing arguments** — it
  takes the same `[-cp <dirs>] [-A:alias…]` surface and rejects unknown
  args (`cljw repl -cp src` used to drop the `-cp` without a
  diagnostic). A new per-commit gate
  (`scripts/check_entrypoint_surface.sh`) requires every CLI entry point
  to be classified and reach the shared classpath resolution, so a
  future subcommand cannot repeat the nREPL omission.

### Changed

- The embedded Wasm runtime is pinned to **zwasm v2.5.0** (was v2.4.1),
  which brings full WASI 0.3 coverage and completes `libzwasm.a`'s C-API
  exports. Neither reaches cljw's embedding surface — cljw drives
  Engine/Module/Instance through Zig on the JIT-default `.auto` engine —
  so this lands the final release on zwasm's current stable rather than
  changing behaviour. zwasm continues under separate maintainership.

## [1.9.0] - 2026-08-05

**Upgrade if you run untrusted code under `cljw.eval/with-budget`, parse
untrusted JSON/EDN, use long-running programs (the GC got a lot faster on
them), or want named groups / lookbehind / `\A \z \Z` / class algebra in
regexes.** MINOR rather than PATCH because behaviour changes: code that
relied on a blocking call outliving its budget now raises.

### Changed

- **The eval budget's wall-clock deadline now bounds blocking calls — all of
  them.** `(Thread/sleep 25000)` under a 3 s deadline used to return normally
  after 25 s; `@(promise)` under a deadline used to park forever. Every
  blocking primitive (`future`/`promise` deref, timed deref, `Thread/sleep`,
  `await`) now waits on a latch bounded by `min(caller timeout, budget
  deadline)`.
- **The budget follows the work, not the thread.** A `Thread.`, `future` or
  agent action spawned inside a `with-budget` extent inherits the budget —
  same absolute deadline, same shared (atomic) step ceiling — and keeps it
  even if it outlives the extent. A spawned 60 s sleep under a 500 ms
  deadline used to hold the process for the full 60 s; it now dies at the
  deadline. A compute loop cannot escape the step ceiling by moving onto a
  spawned thread.
- **A rejection caused by bad DATA is now catchable.** Malformed JSON/EDN
  input, wrong-typed arguments (`clojure.string/replace`, `deliver`, walk
  callbacks, `*out*` bindings), malformed form shapes under `eval` /
  `read-string` (libspecs, destructuring, `ns` directives, reader
  conditionals) and malformed regex patterns all raise catchable errors, as
  JVM Clojure does — ~60 sites reclassified, each verified against the
  oracle. Genuinely unsupported features stay deliberately uncatchable.
  Messages improve with it: "deliver: expected a promise, got integer"
  instead of "… is not supported in ClojureWasm".

### Added

- **Regex: named groups** `(?<name>e)` (with `(.group m "name")`),
  **lookbehind** `(?<=)` / `(?<!)`, **`\A` `\z` `\Z` anchors**, **nested
  character-class unions** `[a[b]]` and **`&&` intersection**
  (`[a-z&&[^m-p]]`), and empty alternatives/groups (`()`, `a|`).
  Backreferences are declined by design — the matcher guarantees linear-time
  matching (the RE2 posture), and a backreference would force backtracking.
- **Multi-dimensional `aget` / `aset`** and the 8 typed `aset-*` multidim
  arms: `(aget a i j)`, `(aset a i j v)` on nested arrays, exactly clj's
  variadic recursion.

### Fixed

- **Long-running programs stopped paying a 2-4x GC tax.** The collection
  trigger is steered by the measured GC time share (the same control variable
  SubstrateVM sizes its heap with), and live-set accounting now counts what
  an object owns (string payloads, array elements, bignum limbs) instead of
  only its 32-byte record. A breadth-first search went 58.9 s → 17.7 s
  (1624 → 114 collections); a 200k-string workload went 263 → 55 collections.
  Short scripts and benchmarks are unchanged.
- **`@(future (Thread/sleep 2000))` ran 17% long** (2321-2358 ms) with no
  budget armed at all — the cancel poll sliced every worker sleep. Waits are
  latch-based now: 2000-2001 ms, and `future-cancel` wakes a sleeping worker
  in 0 ms instead of up to 20 ms.
- **`(Thread/sleep <huge long>)` aborted the process** with an integer
  overflow; it now sleeps, as clj does.

## [1.8.0] - 2026-08-04

**Upgrade if you use Wasm components, or if you use `doc` / `find-doc`.**
A component with more than one export could not be loaded at all, and `doc` on
most of `clojure.core` printed nothing.

### Added

- **`clojure.core.reducers`.** The full sequential surface — `r/map`,
  `r/filter`, `r/remove`, `r/mapcat`, `r/flatten`, `r/take`, `r/take-while`,
  `r/drop`, `r/reduce`, `r/fold`, `r/foldcat`, `r/cat`, `r/monoid`,
  `r/append!` — with the curried one-arity forms. 31 of 32 probed expressions
  are byte-identical to JVM Clojure; the one difference is set print order.
  `fold` computes the same value as upstream's but never in parallel: there is
  no ForkJoinPool here, so it takes the same single-reduce arm upstream itself
  takes for lists, ranges and sets. Its docstring says so.
- **`wasm/run` takes `:max-output-bytes` and `:timeout-ms`**, alongside the
  existing `:fuel` and `:max-memory-pages`. Both default to finite values
  (16 MiB per captured stream, 60 s); `0` or a negative value opts out.

### Fixed

- **A Wasm component with two or more exports failed to load.** Every fixture
  in this project and in zwasm exported exactly one function, so
  `(:require ["x.wasm" :as x])` — the headline feature — had only ever been
  exercised on single-function components. Fixed in zwasm v2.4.1, which this
  release pins.
- **`wasm/run` could be made to exhaust host memory.** It buffered the guest's
  stdout and stderr without limit, and the fuel budget does not bound that:
  fuel counts instructions, and how many bytes an instruction writes is the
  guest's choice. Measured, a guest could force ~64 GB before its fuel ran
  out. Also had no wall-clock bound — the same guest could run for roughly 18
  hours inside the default fuel budget.
- **A resource handle from a one-shot `wasm/component-invoke` was already
  invalid when you received it**, because the component was torn down before
  the call returned. Handle numbers are per-instance table indices starting at
  1, so passing it on could silently operate on a *different* resource. The
  component now lives as long as the handle does, and a handle is bound to the
  component that minted it.
- **`result` and `variant` could not be passed INTO a component.** They lifted
  out correctly, so the round-trip the mapping table describes was one-way.
- **`(doc reduce)` printed nothing** — and so did `assoc`, `conj`, `first`,
  `apply`, `=` and 320 others. The generated metadata table covered 246 of 685
  `clojure.core` publics and none of the ~290 implemented as native
  primitives, so `find-doc` and `apropos` were searching a third of core while
  answering as though they had searched all of it. Now 572 of 684.
- **`(clojure.set/intersection)` returned `nil`** where Clojure throws
  `ArityException`, and no var in `clojure.set` reported `:arglists`.

### Changed

- **`clojure.pprint` no longer publishes 49 internal formatter helpers**
  (`cl-tens`, `cl-roman`, `cl-under-1000`, …). Upstream keeps them private;
  they were public here only because they were written as `defn`. `cl-format`
  and the other six documented names are unaffected. Same for five
  `clojure.data` internals and three contrib parser implementation details.
- **`clojure.math` gained docstrings**, written for this runtime rather than
  imported — upstream's all end in a `java.lang.Math` Javadoc URL.

## [1.7.0] - 2026-08-04

**Upgrade if you load Wasm components.** An untrusted component could kill the
host process, and `result` errors were reaching you as generic Wasm traps with
the error value discarded.

### Fixed

- **An untrusted Wasm component could kill the host process.** The component
  marshaller used bare integer casts, which in the shipped ReleaseSafe build
  are process-killing safety panics rather than catchable errors. Two paths
  were reachable: lowering an out-of-range argument (`(c/f 300)` against a WIT
  `u8`), and — worse, because the data is the guest's — lifting a `u64` above
  `i64`'s maximum. Both now go through the same range check the core-module
  `wasm/call` surface has always used. A `u64` beyond `i64` and an `s64`
  beyond 48 bits now lift exactly via BigInt instead of panicking or silently
  becoming a lossy float.

### Changed

- **`result` and `variant` lift as tagged vectors.** `result` is now
  `[:ok v]` / `[:err e]` and `variant` is `[:case-name payload]`, with the
  payload slot omitted when the arm carries none — one destructuring idiom for
  every WIT sum type. This replaces an `err`→throw mapping that **discarded the
  error value**: the old path raised a generic Wasm *trap*, so a component
  returning `err("not found")` reached you as "WebAssembly module trapped" with
  the message gone. Throwing also had no meaning off the return position — a
  `result` nested in a `list` or `record` aborted the whole conversion.
  (ADR-0135 amendment 2.)

### Added

- **`clojure.core/*file*`** — the source being evaluated, matching JVM Clojure:
  the script path when a file runs, and `"NO_SOURCE_PATH"` otherwise. Still
  `^:dynamic`, so tooling can rebind it.

## [1.6.0] - 2026-08-04

**Upgrade if you use threads, futures, promises, or `wasm/run`.** This
release carries four fixes for ways cljw could hang or abort, two of them
outstanding since 1.5.1 (2026-07-17).

### Fixed

- **A live worker at process exit could abort (glibc `abort`).** A
  `future` / `promise` whose worker was still running while the runtime tore
  down could crash the process instead of exiting. `exitBarrier` plus
  deinit-chokepoint guards make a live worker force a daemon-style hard exit
  rather than a teardown under its own feet. Measured: 6 failures in 32 runs
  before, 0 in 96 after. (ADR-0176, AD-056)
- **Thread registration was not a GC safepoint (SIGABRT on x86_64 Linux).**
  The window between spawning a worker and registering it with the collector
  was not a safepoint, so a collection landing in that window could abort.
  Registration is now a safepoint, and the `TooManyThreads`
  run-unregistered fallthrough is closed. (ADR-0175)
- **`(wasm/run …)` ran guests unmetered — an infinite loop in a guest hung
  the host forever.** `wasm/load` has always defaulted to a finite fuel and
  memory budget; `wasm/run` passed no budget at all, so the two sibling
  surfaces had opposite postures. `wasm/run` now takes the same finite
  default. Measured: a spinning guest ran past 15s before, traps
  `out_of_fuel` in about 1s after.
- **`cljw.http.server` could be wedged by one unfinished request.** The
  accept loop had no read deadline, so a client that opened a connection and
  never completed the request head held the whole server — which binds
  0.0.0.0 — indefinitely. A request-head deadline now bounds it. Measured: a
  half-open connection blocked the next client for 12s before, 1s after.
  (Note: a serial server still handles one connection at a time; this bounds
  the wedge, it does not add concurrency.)
- **Namespace names with an empty segment resolved.** `(require (symbol
  "..a.b"))` could load `a.b` because the munge collapsed the doubled
  separator. JVM Clojure refuses such names; so does cljw now. These names
  cannot be written through the reader, so only computed namespace names are
  affected.

### Added

- **`run-server` accepts `:header-timeout-ms`** — how long a connection may
  take to deliver its request head. Default 10000; `0` disables the deadline.
- **`wasm/run` accepts `:fuel` and `:max-memory-pages`** — the same budget
  keys `wasm/load` already took. `0` or negative means unmetered, which is
  how you opt a trusted command out of the new default.

### Changed

- **zwasm pinned to v2.4.0** (its external-consumer release:
  `-Dcompiler-rt` for linking `libzwasm.a` from a non-Zig toolchain, and
  a DCE fix that keeps the WasmGC cohort out of sub-3.0 builds). Neither
  reaches cljw — cljw links zwasm through Zig, which supplies its own
  compiler-rt, and it builds at zwasm's default Wasm 3.0 level where the
  DCE guard is inert. Pin hygiene, not a behaviour follow; `-Dwasm`
  build + the phase16 wasm e2e suite verified green on the new pin.
- **Issues and Pull Requests are open.** Reports of Clojure code that
  behaves differently here than on the JVM are the most useful thing you can
  file; there is an issue template for exactly that. Outside contributors are
  explicitly not asked to follow the internal commit / ledger conventions —
  see CONTRIBUTING.

### Note for upgraders

Two behaviour changes can surface in working code:

1. `(wasm/run …)` is now fuel-bounded by default. A legitimately long-running
   guest that exceeds roughly 1e9 instructions will trap; pass `{:fuel 0}` to
   restore the previous unbounded behaviour.
2. `(require (symbol s))` with a computed `s` containing a leading, trailing,
   or doubled dot no longer resolves. Well-formed names are unaffected.

## [1.5.1] - 2026-07-17

Patch release: dependency follow.

### Changed

- **zwasm pinned to v2.3.0** (the WASI-0.3.0-official inventory-sweep
  release: docs truth-sweep against the officially released WASI 0.3.0,
  `wasi:clocks/system-clock` component-host support, Homebrew
  packaging). No embedding-API, behaviour, or JIT-output change — a
  pure engine follow; cljw's Wasm FFI surface is unchanged.

## [1.5.0] - 2026-07-17

Minor release: the host-class identity & member-surface campaign
(ADR-0174) — class symbols, class identity, and the Java member surface
become uniformly resolvable, precisely diagnosed, and machine-audited;
plus the user-requested Thread lifecycle.

### Added

- **Class symbols resolve as values everywhere**: bare `System` / `Math` /
  `Thread` / `StringBuilder` (java.lang auto-import), fully-qualified
  `java.util.Date` / `java.time.Instant` / …, and `(:import …)`ed names —
  in value position, `instance?`, `resolve`, `group-by class`, and across
  AOT round-trips. `(= java.util.Date (class d))` is identity on ONE
  canonical descriptor per class.
- **`Class` is first-class**: `(class Long)` → `Class` (was a raw internal
  tag leak), `(instance? Class (class 5))` → true.
- **Thread lifecycle** (user-requested): `(Thread. f)` / `(Thread. f name)`,
  `.start`, `.join` (+ ms), `.isAlive`, `.getName`/`.setName`,
  `.setDaemon`/`.isDaemon`, `Thread/yield`, `Thread/onSpinWait`, priority
  constants. JVM-faithful non-daemon default: main waits for live
  non-daemon threads at exit; `Thread/currentThread` returns the real
  per-thread object. Uncaught thunk errors print the JVM-style
  "Exception in thread" stderr line.
- **System close-out**: `getProperties` (map), 0-arg `getenv` (env map),
  `clearProperty`, `identityHashCode`, `gc`, and real stdio streams
  `System/in` / `System/out` / `System/err` (PrintStream-classed;
  `(.println System/err "…")` works; `System/in` reads stdin
  incrementally; `(instance? java.io.OutputStream System/out)` → true).
- **Constants sweep**: `Math/TAU`; `Long`/`Integer`/`Double`
  BYTES/SIZE/MIN_NORMAL; `File` separator/pathSeparator (+Char) +
  `createTempFile`/`listRoots`; `Pattern`'s 9 flag constants + 2-arg
  `Pattern/compile` (CASE_INSENSITIVE/MULTILINE/DOTALL/COMMENTS);
  `BigDecimal` ZERO/ONE/TWO/TEN; `Instant/EPOCH`, `Duration/ZERO`,
  `LocalTime` MIDNIGHT/NOON/MIN/MAX, `LocalDate`/`LocalDateTime`
  MIN/MAX/EPOCH; host-enum `values`/`valueOf` (+ `Month/of`,
  `DayOfWeek/of`).
- **java.time fill**: `Duration/parse` (full ISO-8601 grammar) +
  `Duration/of`, `LocalDate/ofEpochDay`, `LocalTime/ofSecondOfDay` +
  `ofNanoOfDay`.
- `scripts/check_compat_members.sh` — the member-truth gate: compat_tiers
  member lists are now machine-verified against the registered
  descriptors both ways (over-claims and silent omissions both fail);
  deliberately-skipped members are explicit `opaque_members:` rows.

### Changed

- **Host-class names are their JVM FQCNs**: `(class (java.util.Date. 0))`
  → `java.util.Date` (was `Date`), StringBuilder/Thread etc. no longer
  leak the internal `cljw.` prefix. cljw-native types, user records, and
  exceptions keep simple names (AD-003, clarified).
- **Member misses are precise diagnostics**: `(System/getProperties)` on
  a class without that member now says "No matching static method: … in
  class java.lang.System" instead of the misleading "No namespace:
  'System'" — every deliberately-skipped Java member renders this.
- fix(time): pre-year-0 civil date conversion was off by one era
  (`(.getYear (java.time.LocalDate/of -1 12 31))` was wrong); negative /
  5-digit years now print in JVM sign form.

### Breaking

- **`cljw build` artifacts from ≤ 1.4.0 (envelope ≤ v7) are rejected**
  by a 1.5.0 runtime — rebuild with the new `cljw build` (baked class
  constants changed spelling with the FQCN unification).
- `(class …)` output for Java-surface-backed values changed spelling to
  the JVM FQCN (see Changed) — string-matching on the old simple names
  (`"Date"`, `"Instant"`) needs updating; `instance?` / `=` code is
  unaffected (it got strictly more capable).

## [1.4.0] - 2026-07-16

Minor release: the binary-size campaign — the shipped binary shrinks
**9,469,816 → 6,974,584 bytes (−26.3%, now under 7 MB)** with no feature
loss and no safety-check loss (still ReleaseSafe), plus the envelope
format v7 it rides on.

### Changed

- **Binary size: 9.5 MB → 6.97 MB** (macOS arm64; Linux similar). The
  levers, all measured: unwind tables dropped from release builds
  (−739 KB — a stripped binary printed no native trace anyway); the
  AOT bootstrap gains an interned-name constant pool (42% of the blob
  was duplicate encoding) and flate-compressed lazy namespace regions +
  `.clj` sources (decompressed on demand); the embedded zwasm engine
  updated to v2.2.1 (its JIT host-callback thunk collapse, −1.08 MB
  as seen from cljw); shared sort instantiation. Full ledger:
  `.dev/decisions/0172_binary_size_budget_and_ledger.md`, public
  comparison: `docs/works/binary_size.md`.
- **Bytecode envelope format v7** (`.dev/decisions/0173_*.md`): 4-byte
  aligned wire instructions readable in place from the binary,
  per-blob constant pool, chunk `source_file`/`has_handlers` now
  serialized (AOT-restored fns can frame-flatten; error frames in
  bundled namespaces keep their real file labels), headerless nested
  fn chunks. Startup is unchanged within noise; RSS slightly lower.
- **zwasm pinned to v2.2.1** (binary-size campaign release; no API or
  JIT-output change).
- Cross-language benchmark records re-measured 2026-07-16
  (`bench/cross-lang-latest.yaml`, `bench/RELEASE_METRICS.md`: cold
  start ~6 ms on the shipped `-Dwasm` build).

### Breaking

- **`cljw build` artifacts made by 1.3.x (envelope ≤ v6) are rejected
  by a 1.4.0 runtime** with a version error — rebuild the app with the
  new `cljw build`. (Pre-2.0 format policy: the on-disk spec is
  archived per version in `docs/spec/formats/`; decoders are not kept.)

### Added

- `scripts/binary_size_report.sh` — size report / attribution tool +
  the `size_claims` gate (README size claim and the budget ceiling are
  now CI-enforced against the built binary).
- Guard e2e for VM error line:col fidelity across the new instruction
  encoding (`phase16_vm_error_loc_sidecar`).

## [1.3.1] - 2026-07-16

Patch release: Clojure 1.12 method values (`(every? Character/isWhitespace
s)` — the brew-user report), and defrecords gain their mainline
ns-qualified identity (`#user.Pt{…}` printing, reader round-trip, portable
record hash).

### Added

- **Method values (Clojure 1.12, static form)** — a bare `Class/method`
  in value position is the static method as a first-class fn:
  `(every? Character/isWhitespace s)`, `(map Character/toUpperCase "ab")`,
  `(sort-by Math/abs …)` all work as in mainline. (The 1.12
  `Class/.instanceMethod` / `Class/new` forms are tracked for a future
  release.)
- **Record literals read back** — `#user.Pt{:x 1, :y 2}` constructs the
  record through the reader (mainline parity; extra keys land in the
  extmap), so the printed form round-trips.
- **`scripts/nrepl_send.py`** — a dependency-free nREPL debug client
  (eval / describe / completions against a running server).

### Changed

- **Records print ns-qualified** — `#user.Pt{:x 1, :y 2}` (was `#Pt{…}`),
  matching mainline and making the print form readable.
- **Record hash values are portable** — `(hash (->Pt 1 2))` returns real
  Clojure's value (the qualified-name type-hash XOR the map hash),
  completing the 1.3.0 portable-hash work for records.

## [1.3.0] - 2026-07-16

Minor release: mainline-parity deep-dive — the `rt` namespace is gone
(`(resolve '+)` is `#'clojure.core/+`), CIDER completion reaches the
built-in nREPL completion's fidelity (classes and `Class/` static members
complete without `require`), `java.lang.Character` is complete, and
`(hash x)` values are now portable Clojure hash values.

### Added

- **`java.lang.Character` complete** — the full static surface (47 methods
  + 70 static fields incl. the category/directionality constants), with
  classification (`isLetter`, `isDigit`, `getType`, …) evaluated over
  generated UCD 16.0.0 tables — full Unicode, matching the JVM (previously
  ASCII-only). Includes the JDK 21 `isEmoji*` family, `getDirectionality`,
  the char/int overload pairs (`(Character/toUpperCase 97)` → `65`), and
  `.charValue` / `.compareTo` instance methods. The one member out:
  `getName` (explicit unsupported — the Unicode name table's size/value
  trade is tracked).
- **CIDER completion parity** — nREPL `completions` now serves every
  source the built-in serves: special forms + literals, vars with
  dash-fuzzy matching (`ma-i` → `map-indexed`), namespaces/aliases,
  classes, `Class/` static members with camelCase matching
  (`Character/isD` → `isDigit`), and interned keywords — by-name sorted,
  with `(clojure.core)`-correct namespace annotations. Java-interop
  completion works without `require`, from the closed class registry
  (no JVM-internal classpath leak).
- **`defmacro` resolves as a Var** (`#'clojure.core/defmacro`) and
  **`definline`** is available (defn-equivalent surface).
- nREPL `describe` advertises `versions.clojurewasm` (the babashka-style
  key a CIDER REPL banner can render).

### Changed

- **The internal `rt` namespace is GONE** — Zig builtins and bootstrap
  macros intern directly into `clojure.core`, so `(resolve '+)`,
  `(meta #'when)`, `(ns-publics 'clojure.core)`, doc/eldoc/completion
  namespaces, and printed values all match mainline. Kernel helpers live
  in the documented `cljw.internal` namespace. Compiled `.cljwc` archives
  from earlier versions need a rebuild (format v6).
- **Portable hash values** — `(hash x)` now returns real Clojure's value
  for strings, keywords, symbols, doubles, booleans, chars, UUIDs, ratios,
  BigDecimals, and every collection built from them (`(hash "abc")` →
  `74834163` everywhere). Records and identity objects remain
  cljw-specific.
- **`compare` returns mainline's magnitudes** for strings / chars /
  keywords / symbols (`(compare "a" "c")` → `-2`; Java `String.compareTo`
  semantics).
- **`(locking 5 …)` works** (immediates share one monitor; `(locking nil
  …)` errors, matching mainline's NPE).
- **`Double/parseDouble` matches the exact Java grammar** — accepts
  `1.5d`/`1.5F` suffixes and `0x1.8p1` hex floats; rejects lowercase
  `infinity`/`nan` and exponent-less hex.

### Fixed

- `(read-string "@x")` prints as `(clojure.core/deref x)` (was the
  internal `rt/deref`); `clojure.spec.alpha/form` shows
  `clojure.core/int?` (was `rt/int?`); syntax-quote and macroexpansion
  namespaces match mainline throughout.

## [1.2.1] - 2026-07-14

Patch release: the `*cider-error*` buffer works — CIDER renders numbered
causes with stack frames, phase-aware routing, and Show/Hide frame filters
against cljw, instead of "[no stack trace available]".

### Added

- **nREPL `cider/analyze-last-stacktrace` op** (+ the bare alias) — analyzes
  the session's `*e` on demand: one cause per `ex-cause` chain link with
  class / message / printed ex-data / error phase / stack frames
  (innermost-first, with `clj` / `repl` / `project` / `dup` flags and
  navigable `file-url` for on-disk frames). CIDER's rich error buffer and
  its compile-phase inline overlays activate automatically.

### Fixed

- **`*e` is now set for every caught REPL error** — Clojure parity:
  compiler-class errors (an unresolved symbol, a syntax error) previously
  left `*e` untouched; now `(ex-message *e)` works after any error, in both
  the CLI REPL and nREPL sessions.
- **`(throw (ex-info …))` carries a stack trace** — the live call stack is
  stamped on the thrown value, so user throws render frames like runtime
  errors (both backends).
- **nREPL use-after-free** — the 1.2.0 re-architecture fed the per-message
  scratch-owned request source into evals whose products outlive the
  message; long editor sessions could see corrupted strings. The source is
  now copied to the persistent arena.

## [1.2.0] - 2026-07-13

Minor release: the nREPL server is rebuilt to full base-protocol fidelity —
CIDER (and any nREPL editor client) now works end-to-end. Backward-compatible
with 1.1.x.

### Added

- **nREPL `completions` / `complete` ops** — editor completion (CIDER
  company/capf) over the live image: vars, macros, namespaces, aliases,
  `ns/var` qualified prefixes, with type annotations.
- **nREPL `lookup` / `info` / `eldoc` ops** — arglists + docstrings from var
  metadata; CIDER eldoc and `C-c C-d` documentation work.
- **`*1` / `*2` / `*3` / `*e` REPL history** — interned in `clojure.core`
  (upstream shape) and rotated by both the CLI REPL and every nREPL session
  (per-session isolation: tooling-session evals cannot touch your `*1`).
- **nREPL `ns` request handling** — evals honor the request namespace
  (`namespace-not-found` per spec); each session keeps its own current
  namespace, so an `in-ns` in one session never leaks into another.

### Fixed

- **CIDER REPL buffer was unusable** — the read loop blocked with complete
  requests already buffered, stranding pipelined messages off-by-one; the
  REPL prompt never rendered and RET did nothing. The transport now drains
  every buffered message before blocking.
- **Messages over 4 KiB reset the connection** — `C-c C-k` (load-file) on any
  real file killed the session. The receive buffer now grows (16 MiB frame
  cap).
- **Session identity** — every `clone` returned the same id and replies
  ignored the request's `session`; CIDER's two-session model (main + tooling)
  depends on both. Sessions are now distinct UUIDs and every reply echoes the
  request's `session` + `id`.
- **Error replies** — errors now carry the same caret-rendered text the CLI
  prints (was: a bare Zig error name like `NameError`), as the babashka-style
  three-message protocol (`err` → `ex`/`root-ex` + `eval-error` → `done`;
  was: bundled in one dict, which nREPL clients mis-route, plus a double
  `done`). Evaluation stops at the first failing form (JVM parity).
- **`*err*` output** is captured and streamed to the client alongside `*out*`.
- **`describe`** now derives its ops list from the dispatch table (they can
  no longer drift) and reports the real version (was: a stale hardcoded
  `0.1.0-pre`).

## [1.1.0] - 2026-07-12

Minor release: new REPL / tooling surface and Java-interop additions, a batch
of GC-correctness fixes, and a WebAssembly engine bump. Backward-compatible
with 1.0.x.

### Added

- **`clojure.repl` bundled** — `doc`, `find-doc`, `apropos`, `dir`, `demunge`,
  plus a bare `(doc x)` at the interactive prompt (clojure.main parity).
- **`:arglists` / `:doc` metadata** on `clojure.core` and the eager standard
  library vars — CIDER eldoc now resolves argument lists and docstrings.
- **Regex lookbehind** — `(?<=…)` / `(?<!…)` and `Pattern.split`.
- **`format` date/time** — the `%t` / `%T` conversion family (UTC, English).
- **Namespace metadata** — `alter-meta!` / `reset-meta!` on namespaces, and a
  namespace docstring / attribute map merged into the namespace metadata.
- **Java-interop surface** — common `java.util.Arrays` and
  `java.util.Collections` statics, `String` `char[]` forms, and JVM-bit-parity
  Murmur3 hashing.
- **`slurp` / `spit` accept open streams** (the remaining IOFactory arms).
- **WebAssembly FFI on zwasm v2.2.0** — up from v2.0.0 (table64 JIT +
  AOT full-fidelity); hot loops inside a module keep running as native code.

### Fixed

- **GC-correctness batch** — several use-after-free / corruption classes under
  frequent collection: unrooted analysis-time constants, tree-walk
  native-stack intermediates, `recur` reentrancy inside lazy `for`, and a
  `rest`-of-chunked-seq self-allocation hole that could corrupt a growing
  BFS-style queue. All now hold their roots across the collection.
- **Value semantics** — sorted collections work as hash keys / set elements;
  hash-map full-hash collision buckets match Clojure; `count` on a
  `CharSequence` `deftype`; `(var alias/x)` resolves namespace aliases;
  `read-line` reads process stdin; exception `str` / `pr` and
  `*print-readably*` shadowing match Clojure.

## [1.0.1] - 2026-07-02

Patch release: memory-safety fixes found by a post-release audit. No API
changes. Users on 1.0.0 should upgrade — the first item is reachable from
ordinary code.

### Fixed

- **Stack overflow on deep lazy chains** — realizing or counting a lazy
  sequence / cons chain longer than ~400k elements (e.g.
  `(count (repeat 1000000 1))`) crashed the process: the GC mark phase
  descended the object graph recursively on the native stack. Marking now
  uses an explicit gray worklist (O(1) stack for any depth).
- **Use-after-free family during analysis/compilation** — GC values created
  while a form is analyzed, compiled, or AOT-deserialized (literal strings,
  quoted data, chunk constants, macro-expansion intermediates) were not GC
  roots until execution, so a collection mid-analysis (large file loads,
  user-macro expansion) could recycle them — surfacing as per-run-varying
  `Unable to resolve symbol: '<garbage>'` errors, index-out-of-bounds
  panics, or spurious "host-marker method not yet wired" errors when
  loading bigger libraries (instaparse, math.combinatorics). A per-thread
  analysis-roots frame now keeps them alive; `deftype` / `reify` method
  tables are also traced (their method functions could be collected out
  from under a live type).
- **Namespace reflection errors are now catchable** — `ns-resolve`,
  `ns-map`, `ns-name`, `intern`, `create-ns`, `alias`, `find-var` and
  friends raised an uncatchable "not supported" error on a missing
  namespace or wrong-typed argument; Clojure raises a plain catchable
  exception there, and libraries rely on that for capability probes
  (`(try (ns-resolve …) (catch Exception e nil))`). They now match
  Clojure's exception classes.

## [1.0.0] - 2026-07-01

The first **stable** release. ClojureWasm is a JVM-free Clojure runtime written
in Zig, feature-complete for everyday Clojure with a WebAssembly FFI as its
headline capability. The WebAssembly FFI runs on the embedded **zwasm v2.0.0**
engine. Earlier pre-releases were tagged `1.0.0-alpha.*`. SemVer compatibility
guarantees start here.

### Added

- **Clojure language core** — reader, macros, destructuring, the sequence
  library, transducers, protocols, multimethods, `deftype` / `reify` /
  `defrecord`, metadata, namespaces with lazy loading, and the numeric tower
  (long / double / ratio / BigInteger / BigDecimal, JVM-surface semantics).
- **Standard library** — `clojure.core` plus `clojure.string` / `set` / `walk`
  / `zip` / `edn` / `data.json` / `data.csv` / `math` / `pprint` / `test` /
  `tools.cli` and more, reimplemented for the runtime.
- **WebAssembly FFI** — `(wasm/load "mod.wasm")` then `(wasm/call m "fn" …)`:
  load a sandboxed module compiled from any language (Rust, Go, Zig, C) and
  call it like an ordinary function. The FFI is **JIT-compiled by default** via
  the embedded **zwasm v2.0.0** engine, so a hot loop inside a module runs as native code.
- **WebAssembly components as namespaces** — `(:require ["comp.wasm" :as c])`
  pulls a WIT-typed component in like a library; its exports become ordinary
  Vars, with arguments and results as plain Clojure data.
- **CIDER-compatible nREPL** — `cljw nrepl` for live editor-connected eval.
- **Single-binary builds** — `cljw build script.clj -o app` compiles a program
  and the runtime into one self-contained native executable (arm64 / amd64).
- **Concurrency** — atoms, refs (STM), agents, promises, futures.
- **Java-interop surface** — a curated, definition-derived subset of common
  `java.*` classes (String / Math / java.time / BigInteger / BigDecimal /
  Character / …) reimplemented natively; see `data/compat_tiers.yaml`.

### Notes

- Behavioural equivalence with JVM Clojure is the target on the user-observable
  surface; intentional divergences are catalogued in
  [`docs/clojure_vs_clojurewasm.md`](docs/clojure_vs_clojurewasm.md).
- Licensed under EPL-2.0; third-party components in
  [`legal/THIRD_PARTY.md`](legal/THIRD_PARTY.md).
