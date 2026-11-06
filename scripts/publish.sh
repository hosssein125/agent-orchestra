#!/usr/bin/env bash
# publish.sh — sync this workspace's TOOLING to the public agent-orchestra
# repo as a sanitized export. The public repo is NOT a mirror: the private
# ledger (transcripts, heartbeats, sessions, feature/release records),
# AGENTS.md, prompts/, and the real orchestration.json never leave this
# machine. Public-only files (README, LICENSE, CHANGELOG, CONTRIBUTING,
# orchestration.example.json, templates/, ledger placeholders) are owned by
# the public repo and are never touched.
#
# What syncs: scripts/ hooks/ docs/ rules/ wholesale, plus the ledger
# process docs (ledger/README.md, ledger/releases/README.md).
#
# Usage:
#   scripts/publish.sh            sync into a fresh clone + commit (no push)
#   scripts/publish.sh --push     also push to the public repo's main
#   scripts/publish.sh --dry-run  show what would change; commit nothing
#
# Env: PUBLIC_REPO=<url>  override the target (default: the 'public' remote)
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COORD="$(cd "$SCRIPTS_DIR/.." && pwd)"
PUBLIC_REPO="${PUBLIC_REPO:-$(git -C "$COORD" remote get-url public 2>/dev/null || echo https://github.com/hosssein125/agent-orchestra.git)}"

dry=0; push=0
for a in "${@:-}"; do case "$a" in
  --dry-run) dry=1 ;;
  --push)    push=1 ;;
  *) sed -n '2,19p' "$0" >&2; exit 1 ;;
esac; done

TMP="$(mktemp -d)"; WORK="$TMP/agent-orchestra"
trap 'rm -rf "$TMP"' EXIT

git clone --quiet "$PUBLIC_REPO" "$WORK"
cd "$WORK"

# --- whitelist copy: replace wholesale; public-only files untouched --------
for d in scripts hooks docs rules; do
  [[ -d "$COORD/$d" ]] || continue
  rm -rf "$d"
  cp -r "$COORD/$d" .
done
mkdir -p ledger/releases
cp "$COORD/ledger/README.md" ledger/README.md
cp "$COORD/ledger/releases/README.md" ledger/releases/README.md

# --- guard: refuse to publish anything private (belt & suspenders — the
# copy whitelist already excludes these; this catches future whitelist
# mistakes) ------------------------------------------------------------------
git add -A
leak=""
while IFS= read -r f; do
  if [[ "$f" =~ (^|/)(AGENTS\.md|orchestration\.json|sessions\.json|tasks\.json|activity\.log)$ ]] \
     || [[ "$f" =~ (^|/)(messages|heartbeats|prompts)/ ]] \
     || [[ "$f" =~ (FEAT|REL)-[0-9]{8} ]]; then
    leak+="$f  "
  fi
done < <(git diff --cached --name-only)
[[ -n "$leak" ]] && { echo "error: private files staged for the PUBLIC repo: $leak" >&2; exit 1; }

if [[ $dry == 1 ]]; then
  echo "== dry run — changes that would be committed to the public repo:"
  git diff --cached --stat
  exit 0
fi

if git diff --cached --quiet; then
  echo "public repo already up to date — nothing to publish"
  exit 0
fi
git commit -qm "publish: sync tooling from workspace ($(date '+%Y-%m-%d %H:%M'))"
git show --stat --oneline HEAD | head -25
if [[ $push == 1 ]]; then
  git push --quiet origin HEAD:main
  echo "pushed to $PUBLIC_REPO (main)"
else
  echo "committed locally in the temp clone only — re-run with --push to publish"
  exit 0
fi
