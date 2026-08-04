---
paths:
  - "**"
---

# Orphan-prevention discipline

A background long-runner that outlives a bash turn gets re-parented to
PID 1 on session interrupt and can spin a core (Mac fan event). Two
incident narratives (2026-05-28 REPL-pipe poll-spin, 2026-05-31
clj-oracle infinite-seq) live in
[`ADR-0049`](../../.dev/decisions/0049_orbstack_linux_gate_retired.md)
§ Context.

## The rules

1. **Every `Bash(run_in_background: true)` that drives a long-running
   child** — REPL pipe, SSH shell, bench loop, gate, daemon —
   **MUST be wrapped in `timeout 600 …`** (larger only when justified,
   e.g. `timeout 1800` for a slow Linux gate). Never omit the wrap.
2. **Every `clj -M -e '…'` oracle probe MUST be `timeout 20`-wrapped
   AND bound sequence-producers with `(take N …)`.** `clojure.main -e`
   prints its result, so an unbounded seq (`(range)`, `(iterate inc 0)`,
   `(repeat 1)`, `(cycle …)`, `(line-seq …)`) realises forever and
   pins ~160 % CPU. **Watch the NON-OBVIOUS infinite producers too**:
   `(take-nth 0 coll)` / `(take-nth -n coll)` returns clj's infinite
   `(first coll)` repeat; `(partition n step coll)` with `step` ≤ 0;
   `(repeatedly f)` 0-arity.
3. **Every batched / scripted `clj` invocation MUST cap the JVM heap with
   `-J-Xmx2g`** (e.g. `timeout 60 clj -J-Xmx2g -M batch.clj`). The 2026-06-12
   incident: an unbounded `(take-nth 0 …)` slipped into a `clj_diff_sweep`
   batch and an UNCAPPED JVM realised the infinite seq for the full `timeout 60`
   window, exhausting ~138 GB of system memory + swap (Mac froze). `timeout`
   alone does NOT bound memory — only CPU-time. `-J-Xmx2g` makes a runaway hit a
   JVM `OutOfMemoryError` in seconds (the process dies) instead of consuming all
   system RAM. 2g is ample for any legit batch. **`ulimit -v` does NOT work for
   `cljw`** (the native binary reserves a large virtual address space and fails
   to start under a `-v` cap) — bound cljw via `timeout` + the
   `(take N …)`-every-producer rule instead, never `ulimit -v`.

`timeout` kills only its immediate child, NOT descendants in another
process group: across an SSH/VM boundary the remote command keeps
running (use `ssh host 'timeout 600 cmd'` or
`-o ServerAliveInterval=30`); a `setsid`/`nohup` grandchild survives
too. Prefer one-shot `cljw -e '…'` / heredoc (per
[`cljw_invocation.md`](cljw_invocation.md)) over long-lived REPL pipes.

## Gate launcher

`bash scripts/run_gate.sh` (preferred over raw `test/run_all.sh`) reaps
any prior `run_all.sh` tree + PID-1-orphaned `cljw` before launching a
single gate; `bash scripts/run_gate.sh reap` reaps without launching.
`bash scripts/cleanup_orphans.sh` (etime > 30 min, wired as a SessionStart
hook in `.claude/settings.json`) is the cross-session backstop: it reaps
PID-1-orphaned `run_all.sh` / `run_gate.sh` trees, this repo's `cljw`, and
stray `clojure.main -e` oracle JVMs. `--dry-run` lists without killing.

This lived at `~/.claude/hooks/cleanup_orphans.sh` until 2026-08-04 — outside
the repo, so no clone ever had it, and it was absent on the maintainer machine
too. It is in-repo now so the guarantee this rule's disciplines assume is one
that actually runs (D-565).

## Counter-examples

- ❌ `ssh ubuntunote 'bash test/run_all.sh'` in background, no
  `timeout` — orphaned remote shell on session kill.
  ✅ `timeout 600 bash scripts/run_remote_ubuntu.sh`.
- ❌ `clj -M -e '(range)'` — unbounded print, no timeout.
  ✅ `timeout 20 clj -M -e '(take 5 (range))'`.
- Reap a stray oracle JVM: `pkill -f 'clojure.main.*-e'` (scoped —
  leaves IntelliJ / Gradle / interactive REPLs untouched).

## Related

- [`ADR-0049`](../../.dev/decisions/0049_orbstack_linux_gate_retired.md)
  § Context — full incident narratives.
- `~/.claude/CLAUDE.md` § 全プロジェクト共通 — global orphan advisory +
  the SessionStart cleanup hook.
- [`cljw_invocation.md`](cljw_invocation.md) — safe `cljw` entry points
  that avoid long-lived REPL pipes.
