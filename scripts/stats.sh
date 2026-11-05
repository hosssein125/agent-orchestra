#!/usr/bin/env bash
# stats.sh — cost & activity report from ledger/activity.log (R22 without the
# hand-counting). What the top orchestration platforms expose as "usage
# dashboards", from a plain append-only log.
#
# Usage:
#   scripts/stats.sh                 per-role totals: dispatches, wall time,
#                                    token in/out
#   scripts/stats.sh --daily         per-day rollup across roles
#   scripts/stats.sh --since 2026-11-05   only entries on/after this date
#   scripts/stats.sh --json          machine-readable (one JSON object)
#
# Token numbers are the CLI envelope's usage block per relay END line — mostly
# cache reads; treat them as relative cost signal, not invoice truth.
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPTS_DIR/lib.sh"
coord_paths || die "cannot locate the coordination workspace"
ACTIVITY="$COORD_DIR_LIB/ledger/activity.log"

daily=0; json=0; since=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --daily) daily=1; shift ;;
    --json)  json=1; shift ;;
    --since) since="$2"; shift 2 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "error: unknown arg '$1'" >&2; exit 1 ;;
  esac
done

[[ -f "$ACTIVITY" ]] || { echo "(no activity yet — $ACTIVITY missing)"; exit 0; }

# awk does the parsing; bash does the formatting. FS=' | ' splits log lines.
report="$(awk -F' \\| ' -v since="$since" '
  $1 < since && since != "" { next }
  /^....-..-.. ..:..:.. / {
    d = substr($1, 1, 10)
    if ($2 ~ /START/)  { starts[$3]++; dstarts[d]++ }
    if ($2 ~ /FAILED/) { fails[$3]++; dfails[d]++ }
    if ($2 ~ /END/) {
      dur = $5; sub(/s.*/, "", dur); secs[$3] += dur; ends[$3]++
      if (match($6, /in=[0-9]+/))  { tin[$3] += substr($6, RSTART+3, RLENGTH-3); dtin[d] += substr($6, RSTART+3, RLENGTH-3) }
      if (match($6, /out=[0-9]+/)) { tout[$3] += substr($6, RSTART+4, RLENGTH-4); dtout[d] += substr($6, RSTART+4, RLENGTH-4) }
      dsecs[d] += dur
    }
  }
  END {
    for (r in starts) print "ROLE " r, starts[r]+0, ends[r]+0, fails[r]+0, secs[r]+0, tin[r]+0, tout[r]+0
    for (d in dstarts) print "DAY " d, dstarts[d]+0, dsecs[d]+0, dfails[d]+0, dtin[d]+0, dtout[d]+0
  }' "$ACTIVITY")"

if [[ $json -eq 1 ]]; then
  # emit {"roles":{...},"days":{...}} without requiring jq
  node -e '
    const lines = process.argv[1].split("\n").filter(Boolean);
    const out = { roles: {}, days: {} };
    for (const l of lines) {
      const t = l.split(" ");
      if (t[0] === "ROLE") out.roles[t[1]] = { starts:+t[2], ends:+t[3], fails:+t[4], wallSec:+t[5], tokensIn:+t[6], tokensOut:+t[7] };
      if (t[0] === "DAY")  out.days[t[1]]  = { starts:+t[2], wallSec:+t[3], fails:+t[4], tokensIn:+t[5], tokensOut:+t[6] };
    }
    console.log(JSON.stringify(out, null, 2));' "$report"
  exit 0
fi

hum_tok() { # 1234567 -> 1.2M
  local n="$1"
  if   (( n >= 1000000 )); then awk -v n="$n" 'BEGIN{printf "%.1fM", n/1000000}'
  elif (( n >= 1000 ));    then awk -v n="$n" 'BEGIN{printf "%.1fk", n/1000}'
  else echo "$n"; fi
}
hum_sec() { # 3940 -> 1h 6m
  local s="$1"
  if (( s >= 3600 )); then echo "$(( s/3600 ))h$(( (s%3600)/60 ))m"
  elif (( s >= 60 )); then echo "$(( s/60 ))m"
  else echo "${s}s"; fi
}

if [[ $daily -eq 1 ]]; then
  printf '%-12s %9s %10s %7s %10s %10s\n' DAY DISPATCHES WALL FAILS TOK_IN TOK_OUT
  while read -r _ d st sc fa ti to; do
    [[ -n "$d" ]] || continue
    printf '%-12s %9s %10s %7s %10s %10s\n' "$d" "$st" "$(hum_sec "$sc")" "$fa" "$(hum_tok "$ti")" "$(hum_tok "$to")"
  done < <(echo "$report" | grep '^DAY' | sort)
  exit 0
fi

printf '%-16s %11s %9s %6s %10s %10s %10s\n' ROLE DISPATCHES ENDS FAILS WALL TOK_IN TOK_OUT
tst=0; tse=0; tf=0; tsec=0; tin=0; tout=0
while read -r _ r st en fa sc ti to; do
  [[ -n "$r" ]] || continue
  printf '%-16s %11s %9s %6s %10s %10s %10s\n' "$r" "$st" "$en" "$fa" "$(hum_sec "$sc")" "$(hum_tok "$ti")" "$(hum_tok "$to")"
  tst=$((tst+st)); tse=$((tse+en)); tf=$((tf+fa)); tsec=$((tsec+sc)); tin=$((tin+ti)); tout=$((tout+to))
done < <(echo "$report" | grep '^ROLE' | sort)
echo "─"
printf '%-16s %11s %9s %6s %10s %10s %10s\n' TOTAL "$tst" "$tse" "$tf" "$(hum_sec "$tsec")" "$(hum_tok "$tin")" "$(hum_tok "$tout")"
