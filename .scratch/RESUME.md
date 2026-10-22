# CLJW-PERF-STARTUP resume (card 20261022150542-05d73990)
State: O-090 (serialize.zig quoted-list scratch from ctx.allocator) built, measured, ledgered; D-610 records the residual. Commit pending on a green smoke (/tmp/ps_smoke.log).
Measured (perf stat -r 20, load 10-45 so task-clock not wall): cljw -e nil task-clock 38.8 -> 27.3 ms (bb 29.1), faults 2741 -> 1792 (bb 4868). Pinned taskset -c 2: kernel instr 29.3M -> 12.3M (bb 26.8M); user 61.6M unchanged (bb 16.2M).
CLJW_PROFILE_STARTUP: prefix 1-7 ms (noisy), runEnvelope 13-24 ms.
Drafted, NOT measured (build-lock wait), reverted: referAllImpl getOrPut+reserve. Worth a real A/B.
Next levers (D-610): vm_arena 868 KB threadlocal makes TLS 1.17 MB, memset twice (vm.zig, out of scope); shared clojure.core refer table; readCollection; lazy ns replay during eager.
Binaries: /tmp/ps/cljw-base (before), /tmp/ps/cljw-o091 (after), /tmp/ps/prof2 (-Dprofile).
PR: https://github.com/BuddhiLW/ClojureWasm/pull/87 (opened 2026-10-22). Pending: confirm the final smoke (/tmp/ps_smoke.log) and note the result on the PR.
