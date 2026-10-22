# CLJW-PERF-STARTUP resume (card 20261022150542-05d73990)
State: merged origin/staging. WIP commit swaps page_allocator for ctx.allocator in serialize.zig quoted-list decode (927 mmap+munmap pairs per cold start). Not yet built or measured with this change.
Baseline (load ~13, min of 20 interleaved): cljw -e nil 37.0 ms vs bb 41.0; hello 35.9 vs 39.8. perf stat task-clock: cljw 33.4 ms vs bb 25.8. CLJW_PROFILE_STARTUP: runEnvelope 23.2 ms of 24.6 setupCoreAot.
perf (/tmp/ps, -Dprofile): 40% kernel (mmap/munmap from serialize readValue list buf, page faults); readCollection alloc 0xAA memset (ReleaseSafe) ~15%; referAllImpl ~10% (re-refer core per ns); loadRegionNamespace (a lazy ns required during the eager replay) ~5%.
Next: build with the fix (prof2 build at /tmp/ps/prof2 is running), measure, then cut the readCollection memset/alloc, referAll dupes, and the lazy require during eager replay. Ledger O-090+, debt D-610+.
