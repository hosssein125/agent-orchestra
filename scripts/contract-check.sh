#!/usr/bin/env bash
# contract-check.sh — the contract-gate verifier as a tool (encodes R24).
#
# A role's reply states where its contract/artifact note lives, but the stated
# path may be relative, abbreviated, or drift from where the file actually
# landed. This resolves it instead of string-matching it:
#   1. as stated (absolute or cwd-relative)
#   2. under the repo root as stated
#   3. by filename anywhere under the repo (bounded to depth 6)
#
# Usage:
#   scripts/contract-check.sh <repo-root> <stated-path>
# Exit 0 + resolved path on stdout when found; exit 1 when it is not.
set -euo pipefail

repo="${1:-}"; stated="${2:-}"
[[ -n "$repo" && -n "$stated" ]] || { sed -n '2,14p' "$0" >&2; exit 1; }
repo="${repo%/}"
[[ -d "$repo" ]] || { echo "error: repo root not found: $repo" >&2; exit 1; }

base="$(basename "$stated")"

try() { [[ -n "$1" && -f "$1" ]] && { echo "$1"; exit 0; }; return 0; }

# 1. as stated (absolute, or relative to cwd)
try "$stated"
# 2. under the repo root, as stated (also without any leading docs/ noise dirs)
try "$repo/$stated"
first="${stated%%/*}"
if [[ "$first" != "$stated" ]]; then try "$repo/${stated#*/}"; fi
# 3. fuzzy: same filename under the repo, shallow find, contract dirs first
for root in "$repo/Docs" "$repo/docs" "$repo"; do
  [[ -d "$root" ]] || continue
  hit="$(timeout 20 find "$root" -maxdepth 6 -name "$base" -type f 2>/dev/null | head -n 1)"
  try "$hit"
done

echo "NOT FOUND — stated '$stated', basename '$base', no match under $repo" >&2
exit 1
