#!/usr/bin/env bash
# search.sh — full-text search across the ledger: every message transcript,
# heartbeat line, and feature file. The audit trail is only useful if you can
# find things in it (the analog of "session search" in the big orchestration
# platforms — over plain files, with no index to maintain).
#
# Usage:
#   scripts/search.sh <pattern>            case-insensitive regex
#   scripts/search.sh -r backend <pat>     only that role's transcripts
#   scripts/search.sh -n 5 <pat>           5 context lines per match
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPTS_DIR/lib.sh"
coord_paths || die "cannot locate the coordination workspace"
LEDGER="$COORD_DIR_LIB/ledger"

role=""; ctx=2; pat=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -r) role="$2"; shift 2 ;;
    -n) ctx="$2"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) pat="$1"; shift ;;
  esac
done
[[ -n "$pat" ]] || { echo "usage: scripts/search.sh [-r role] [-n ctx] <pattern>" >&2; exit 1; }

targets=( "$LEDGER"/messages "$LEDGER"/heartbeats "$LEDGER"/FEAT-*.md )
files=()
for t in "${targets[@]}"; do [[ -e "$t" ]] && files+=( "$t" ); done
(( ${#files[@]} > 0 )) || { echo "(nothing to search yet — no transcripts)"; exit 0; }

# role filter: match transcript filename prefixes only, keep other targets
if [[ -n "$role" ]]; then
  matches="$(grep -rniE --include='*' -C "$ctx" -- "$pat" "${files[@]}" 2>/dev/null | awk -F: -v role="$role" '
    /^--$/ { print; next }
    {
      file = $1
      gsub(/\\/, "/", file)                       # Git Bash grep uses backslashes
      sub(/^.*\/ledger\//, "", file)              # strip the ledger prefix
      if (file ~ /^messages\//) { if (file ~ "^messages/" role "-") print $0 }
      else print $0
    }' | sed 's|^.*/[Ll]edger[/\\]||; s|\\|/|g')"
else
  matches="$(grep -rniE -C "$ctx" -- "$pat" "${files[@]}" 2>/dev/null | sed 's|^.*/[Ll]edger[/\\]||; s|\\|/|g')"
fi

if [[ -z "$matches" ]]; then
  echo "no matches for '$pat'"
  exit 1
fi
echo "$matches"
echo
echo "$(echo "$matches" | grep -cv '^--$' ) matching line(s) in $LEDGER"
