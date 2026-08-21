#!/usr/bin/env bash
# scripts/check_changelog_reachability.sh
#
# `[Unreleased]` must describe what has NOT shipped. An entry that is also
# present in the newest tag's own `[Unreleased]` section went out in that
# release while still reading as forthcoming — CHANGELOG.md is the
# release-history SSOT, so that is a lie to every reader of it.
#
# The check: extract the `## [Unreleased]` body at HEAD and at the newest
# reachable `vX.Y.Z` tag; any content line in both has shipped.
#
# Informational by default (exit 0). Pass --gate to exit 1 on a violation.
set -euo pipefail
cd "$(dirname "$0")/.."

CHANGELOG=CHANGELOG.md
gate=0
[ "${1:-}" = "--gate" ] && gate=1

if [ ! -f "$CHANGELOG" ]; then
  echo "check_changelog_reachability: VIOLATION -- $CHANGELOG is missing." >&2
  [ "$gate" -eq 1 ] && exit 1
  exit 0
fi

# Body of the `## [Unreleased]` section, content lines only (blank lines and
# the heading itself carry no claim).
unreleased_body() {
  awk '
    /^## \[Unreleased\]/ { in_section = 1; next }
    /^## / { in_section = 0 }
    in_section && NF { print }
  '
}

head_body="$(unreleased_body < "$CHANGELOG")"

if [ -z "$head_body" ]; then
  echo "check_changelog_reachability: ok — [Unreleased] is empty, nothing can have shipped early"
  exit 0
fi

newest_tag="$(git tag --sort=-v:refname --merged HEAD 2>/dev/null \
  | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sed -n 1p || true)"

if [ -z "$newest_tag" ]; then
  echo "check_changelog_reachability: ok — no release tag reachable from HEAD to compare against"
  exit 0
fi

tag_body="$(git show "${newest_tag}:${CHANGELOG}" 2>/dev/null | unreleased_body || true)"

if [ -z "$tag_body" ]; then
  echo "check_changelog_reachability: ok — $newest_tag shipped with an empty [Unreleased]"
  exit 0
fi

# Lines claimed as unreleased at HEAD that were ALREADY in the tag's
# [Unreleased] — i.e. they shipped in $newest_tag.
shipped="$(comm -12 \
  <(printf '%s\n' "$head_body" | sed 's/^[[:space:]]*//' | sort -u) \
  <(printf '%s\n' "$tag_body"  | sed 's/^[[:space:]]*//' | sort -u))"

if [ -n "$shipped" ]; then
  count="$(printf '%s\n' "$shipped" | grep -c . || true)"
  echo "check_changelog_reachability: VIOLATION -- $count [Unreleased] line(s) already shipped in $newest_tag:" >&2
  printf '%s\n' "$shipped" | sed -n 1,20p | sed 's/^/    /' >&2
  echo "  Move them under a '## [$( echo "$newest_tag" | tr -d v )]' heading (or the release they belong to)." >&2
  [ "$gate" -eq 1 ] && exit 1
  exit 0
fi

echo "check_changelog_reachability: ok — no [Unreleased] entry has shipped in $newest_tag"
