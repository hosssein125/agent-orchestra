#!/usr/bin/env bash
# release-check.sh — the release-gate verifier as a tool (R12/R28).
#
# A devops reply claims a release/hotfix/rollback shipped: version tagged,
# on main, pushed, and recorded. Trust gates, verify artifacts (R12):
#   1. the tag exists in each repo and is annotated
#   2. it is reachable from main (tagged on main, not a stray branch)
#   3. origin/main contains it too, when an origin remote exists
#      (a successful push updates the local remote-tracking ref — no
#      network needed for this check)
#   4. a ledger/releases/REL-*.md record mentions the version
#
# Usage:
#   scripts/release-check.sh <vX.Y.Z> [<repo-path> ...]
# Repos default to every orchestration.json role repo that is itself a git
# repo (the devops role's parent dir is skipped automatically).
# Exit 0 + per-check verdict lines; exit 1 on any FAIL.
set -euo pipefail
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPTS_DIR/lib.sh"
coord_paths || die "no orchestration.json found"

ver="${1:-}"
[[ "$ver" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { sed -n '2,17p' "$0" >&2;
  die "usage: release-check.sh <vX.Y.Z> [<repo-path> ...]"; }
shift || true

repos=()
if [[ $# -gt 0 ]]; then
  repos=("$@")
else
  for r in $ROLES; do
    p="$(role_repo "$r")"
    [[ -d "$p/.git" ]] && repos+=("$p")
  done
fi
[[ ${#repos[@]} -gt 0 ]] || die "no git repos to check (pass repo paths explicitly?)"

fail=0
for repo in "${repos[@]}"; do
  name="$(basename "$repo")"
  # 1. annotated tag exists
  if git -C "$repo" cat-file -t "$ver" 2>/dev/null | grep -q '^tag$'; then
    echo "tag      $name: OK ($ver, annotated)"
  else
    echo "tag      $name: FAIL (no annotated tag $ver)"; fail=1; continue
  fi
  # 2. reachable from main
  if git -C "$repo" merge-base --is-ancestor "$ver" main 2>/dev/null; then
    echo "on-main  $name: OK"
  else
    echo "on-main  $name: FAIL ($ver not reachable from main)"; fail=1
  fi
  # 3. pushed (origin/main remote-tracking ref contains the tag)
  if git -C "$repo" remote get-url origin >/dev/null 2>&1; then
    if git -C "$repo" branch -r --contains "$ver" 2>/dev/null | grep -q 'origin/main'; then
      echo "pushed   $name: OK (origin/main contains $ver)"
    else
      echo "pushed   $name: FAIL (origin/main does not contain $ver)"; fail=1
    fi
  else
    echo "pushed   $name: SKIP (no origin remote)"
  fi
done

# 4. a ledger record mentions the version
rel_dir="$COORD/ledger/releases"
rel_hit=""
if compgen -G "$rel_dir/REL-*.md" >/dev/null 2>&1; then
  rel_hit="$(grep -l "$ver" "$rel_dir"/REL-*.md 2>/dev/null | head -n 1 || true)"
fi
if [[ -n "$rel_hit" ]]; then
  echo "record   ledger: OK ($rel_hit)"
else
  echo "record   ledger: FAIL (no ledger/releases/REL-*.md mentions $ver)"; fail=1
fi

[[ $fail -eq 0 ]] && echo "RELEASE VERIFIED: $ver" || echo "RELEASE CHECK FAILED: $ver"
exit $fail
