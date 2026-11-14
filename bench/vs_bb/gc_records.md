# GC allocation-record compaction

Partial result for `CLJW-PERF-GC-CHURN`, measured 2026-11-14. The raw five-run
samples are in [`gc_records.yaml`](gc_records.yaml).

## Change and limits

On 64-bit hosts an allocation record occupied 24 bytes: a full pointer, a
usize length and a separate alignment enum. The alignment only needs six bits.
Keeping the pointer and packing size plus alignment into one native metadata
word reduces the record to 16 bytes. The live table, copies when it grows, and
records moved during sweep all become smaller.

This does not compress pointers or move objects. A size above `2^58 - 1` is
refused before allocating a cell, never truncated. The 32-bit representation
retains its full usize size range. Sweep and deinit preserve the size and
alignment originally passed to the allocator. Trigger policy, payload charging,
page retention and sweep order are unchanged.

The inherited forward-sweep-compaction experiment was discarded. Repeated A/B
windows did not establish a benefit. Reducing trigger thresholds was not used:
payload charging already exists, and more collections would repeatedly trace
the retained heap.

## Method

- Baseline: `6c91f001`, the branch base, with a saved baseline executable.
- Zig 0.16.0, `-Dwasm -Doptimize=ReleaseSafe`, same worktree and host.
- One unmeasured warm-up, then five fresh processes per executable and workload.
  Rotate baseline, candidate and bb in each round.
- Main windows pin processes to logical CPU 3. An independent check uses
  logical CPU 19, an E-core without an SMT sibling.
- Time is the minimum script `INPROC_MS`. RSS is the **largest** process peak
  from `/usr/bin/time -v` among the five runs, not the smallest sample.
- `perf stat cpu_core/instructions/u` covers the whole process, including
  startup. Instruction columns use the median. The E-core window has no PMU
  instruction count.
- The shared host was heavily loaded and swap was full. Absolute timings and
  small timing differences are not reliable speed claims.

## Churn

| Window | Baseline ms | Candidate ms | bb ms | Baseline peak KiB | Candidate peak KiB | bb peak KiB |
|---|---:|---:|---:|---:|---:|---:|
| First P-core window | 1375 | 1350 | 1001 | 165140 | 147764 | 176488 |
| Full-suite P-core window | 1538 | 1566 | 1199 | 165244 | 147864 | 177624 |
| Recheck P-core window | 1022 | 1027 | 671 | 165140 | 146812 | 177920 |
| Independent E-core window | 1040 | 920 | 707 | 165140 | 146816 | 192540 |

The first window saves 17,376 KiB (10.5%) peak RSS; every window shows a similar
reduction. Median whole-process user instructions are 6.843 billion before and
6.821 billion after (about 0.32% less). Throughput is approximately unchanged
on the P-core. It remains **1.30 to 1.53 times bb** across these windows, so the
at-most-1.00-times throughput target is **not met**. The RSS target is met.

A separate five-run `CLJW_GC_STATS=3` check on CPU 19 found identical allocation
counts (3,657,408), allocated bytes (177,230,641), live bytes (29,619,025),
collections (8), and mapped/released page counts in both arms. That supports
metadata storage, not altered reclamation or lost roots, as the memory saving.
The diagnostic times include a 5443 ms scheduling outlier in the candidate;
these are not a GC speed claim.

The card's historical 896 ms / 353 MB and bb 434 ms / 180 MB describe an older
baseline. The branch base already includes O-091's right-sized collection
cells. That earlier reduction must not be credited to this change.

## Regression checks

All 15 timed `vs_bb` workloads returned the same `RESULT` across baseline,
candidate and bb. The initial full-suite window, best of five in-process ms:

| Workload | Baseline | Candidate | bb | User instructions delta |
|---|---:|---:|---:|---:|
| arrays | 769 | 775 | 492 | +0.060% |
| dot_loop_nth | 981 | 960 | 925 | -0.003% |
| fib_recursive | 727 | 727 | 604 | -0.093% |
| fn_call | 1432 | 1368 | 973 | -0.003% |
| gc_churn | 1538 | 1566 | 1199 | -0.319% |
| into_collections | 4832 | 4629 | 962 | -0.050% |
| into_map_only | 515 | 554 | 203 | -0.508% |
| json_roundtrip | 657 | 722 | 976 | -0.032% |
| lazy_chain | 2567 | 2562 | 1201 | -0.322% |
| numeric_doubles | 1946 | 1707 | 1363 | +0.019% |
| protocol_dispatch | 1584 | 1728 | 1086 | -0.048% |
| reduce_map | 7491 | 8477 | 1233 | -0.009% |
| string_ops | 1049 | 899 | 770 | -0.176% |
| transduce | 5029 | 4752 | 542 | +0.013% |
| vector_assoc | 817 | 899 | 533 | -0.092% |

Apparent slowdowns were rechecked in a second interleaved five-run window:
arrays 715 to 712 ms, into_map_only 379 to 350, json_roundtrip 526 to 355,
protocol_dispatch 1347 to 1246, vector_assoc 1117 to 1088. `reduce_map` was
6354 to 6736 ms on the contended P-core, but 4486 to 4512 ms (+0.6%) on the
independent E-core, with CPU time 3.82 to 3.77 seconds. Its median instruction
count did not grow. No repeatable throughput regression was established;
these noisy measurements do not prove the absence of one.

Native vector_ops, map_ops, list_build, gc_stress, nested_update, gc_alloc_rate
and gc_large_heap were also run five times per executable, twice, with matching
output. Their short process-wall measurements are startup/contention dominated.
The raw recheck is included in the datum. `into_transient_checks` is not a
cross-runtime timed workload: bb lacks the tested transient-map operation.

## Correctness

- `zig build test -Dwasm -j2` passed after the final test changes.
- `bash test/run_all.sh --smoke e2e_phase16_gc_torture --resume` passed: 17
  steps, zero failures, including GC torture, 5515/5515 corpus golden outputs,
  and 986 Clojure tests with 5235 assertions.
- Zlinter was skipped because its dependency could not be resolved offline;
  this is not a claim that lint ran.
- Tests cover every allocator alignment, maximum representable sizes, full
  pointer roundtrips, pre-allocation refusal, and exact sweep/deinit frees of
  small, tail-allocated large and over-aligned cells under `testing.allocator`.
- The final release executable SHA-256 matches the measured candidate in the
  datum. Strengthening the tests did not change the benchmarked executable.
