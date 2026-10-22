# CLJW-E2E-SWEEP phase16 resume (card 20260909231443-121d741e, branch swarm/e2e-phase16)

Commit 1: 17 phase16 scripts migrated (agent, locking, concurrency_stress, java-io family,
reducers / repl / json_fs / tokenizer, extend_via_metadata, bfs_queue_gc) into the suites
agent_test, locking_test, java_io_family_test, core_libs_phase16_test, gc_heap_return_test.
Baseline 322 -> 305. Smoke test_clj_suites green (881 tests, 156 suites).

Remaining phase16 (19): eval_budget gc_torture http_client http_server load_file_source
repl_classpath stdin_read_line vm_error_loc_sidecar wasm_* (12), zig_native (already marked).
Next: merge origin/staging; classify each remaining script as in-process (migrate) or
process-boundary (mark with `# e2e-process-boundary: <reason>`).
