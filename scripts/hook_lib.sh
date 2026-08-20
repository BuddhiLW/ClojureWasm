#!/usr/bin/env bash
# scripts/hook_lib.sh
#
# Shared helpers for PreToolUse / PostToolUse hooks.
# Source this file from each `scripts/check_*.sh`:
#
#     source "$(dirname "$0")/hook_lib.sh"
#
# Helpers:
#
#   hook_cd_project_root           — cd to $CLAUDE_PROJECT_DIR or git
#                                     toplevel; safe to call before
#                                     argument parsing.
#   hook_read_command [VAR]        — read hook stdin payload, decode
#                                     JSON, write command to global
#                                     $HOOK_COMMAND (or to VAR if
#                                     argument supplied). Exits 1 on
#                                     decode failure (fail-closed —
#                                     never silently allow).
#   hook_is_git_push [CMD]         — match `git push` anywhere in CMD
#                                     (or $HOOK_COMMAND). Returns 0 if
#                                     so, else 1.
#   hook_is_git_commit [CMD]       — same for `git commit`.
#   hook_nested_worktree_paths     — print each git worktree nested
#                                     INSIDE this checkout, one
#                                     repo-relative path per line.
#                                     Empty when there are none.
#   hook_rg_exclude_worktrees      — print `--glob !<path>/**` argument
#                                     pairs (one per line) for those
#                                     worktrees; read into an array and
#                                     pass to `rg` so a tree walk stays
#                                     inside this checkout.
#   hook_iter_unpushed CALLBACK    — for each commit in `@{u}..HEAD`
#                                     (or `HEAD` if no upstream), call
#                                     CALLBACK with the SHA. Fails
#                                     closed if `git rev-list` errors.
#
# Discipline source: Wave 16 (2026-05-26) C7 extraction; before this
# the JSON-parse + project-root-cd + git-push regex was duplicated
# across `check_smell_audit.sh`, `check_facts_immutable.sh`,
# `check_md_tables.sh`, `check_learning_doc.sh`, and
# `check_provisional_sync.sh`. The library lifts the shared shape; each
# hook keeps its concern-specific logic (`is_source_path()` /
# `is_marker_scope()` / etc.) inline because the boundary between
# concerns is not the same per hook.

[[ -n "${HOOK_LIB_LOADED:-}" ]] && return 0
HOOK_LIB_LOADED=1

hook_cd_project_root() {
  cd "${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
}

hook_read_command() {
  local _input
  if ! _input="$(cat)"; then
    echo "internal: failed to read hook payload from stdin" >&2
    exit 1
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    echo "internal: python3 missing — cannot parse hook payload" >&2
    exit 1
  fi

  # Capture stdout only; Python's stderr (decode-failure diagnostics +
  # any latent warnings) goes to the terminal so it cannot pollute the
  # parsed command via a stderr→stdout fold. The script's own exit
  # check (below) handles the decode-failure case fail-closed.
  local _cmd
  if ! _cmd="$(printf '%s' "$_input" | python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
except Exception as e:
    sys.stderr.write(f"internal: hook payload decode failed: {e}\n")
    sys.exit(1)
print((data.get("tool_input") or {}).get("command", "") or "")
')"; then
    echo "internal: hook payload parse error — failing closed" >&2
    exit 1
  fi

  if [[ -n "${1:-}" ]]; then
    printf -v "$1" '%s' "$_cmd"
  else
    HOOK_COMMAND="$_cmd"
  fi
}

hook_is_git_push() {
  local _cmd="${1:-${HOOK_COMMAND:-}}"
  printf '%s' "$_cmd" | grep -qE '(^|[ ;&|])git[[:space:]]+push([[:space:]]|$)'
}

hook_is_git_commit() {
  local _cmd="${1:-${HOOK_COMMAND:-}}"
  printf '%s' "$_cmd" | grep -qE '(^|[ ;&|])git[[:space:]]+commit([[:space:]]|$)'
}

hook_nested_worktree_paths() {
  local _root _wt
  _root="$(git rev-parse --show-toplevel 2>/dev/null)" || return 0
  git worktree list --porcelain 2>/dev/null \
    | while read -r _key _wt; do
        [[ "$_key" == "worktree" ]] || continue
        [[ "$_wt" == "$_root" ]] && continue
        [[ "$_wt" == "$_root"/* ]] || continue
        printf '%s\n' "${_wt#"$_root"/}"
      done
}

hook_rg_exclude_worktrees() {
  local _rel
  while IFS= read -r _rel; do
    [[ -z "$_rel" ]] && continue
    printf '%s\n%s\n' "--glob" "!${_rel}/**"
  done < <(hook_nested_worktree_paths)
}

hook_iter_unpushed() {
  local _callback="$1"
  local _upstream _range _rev_out

  _upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || echo '')"
  if [[ -n "$_upstream" ]]; then
    _range="$_upstream..HEAD"
  else
    _range="HEAD"
  fi

  if ! _rev_out="$(git rev-list "$_range" 2>&1)"; then
    echo "internal: git rev-list $_range failed — failing closed" >&2
    echo "$_rev_out" >&2
    exit 1
  fi

  while IFS= read -r _sha; do
    [[ -z "$_sha" ]] && continue
    "$_callback" "$_sha"
  done <<< "$_rev_out"
}
