#!/usr/bin/env bash
# watch.sh — see what the orchestration is doing, live.
#
# Usage:
#   scripts/watch.sh status          snapshot: features, sessions, activity,
#                                    agent heartbeats, product-repo states
#   scripts/watch.sh ui [seconds]    full-screen auto-refreshing dashboard
#                                    (default 5s; q quits, any key refreshes;
#                                    WATCH_ONCE=1 renders one frame and exits)
#   scripts/watch.sh live [role]     follow activity.log + heartbeat files
#                                    (backend|admin-front|customer-front, or
#                                    all when omitted). Ctrl-C to stop.
#
# Sources:
#   ledger/activity.log             every relay START/END/FAILED (relay.sh)
#   ledger/heartbeats/<role>.md     one line per meaningful step, written by
#                                    the role agents themselves
#   ledger/FEAT-*.md                feature statuses
#   product repos' git state        branch + dirty-file count (live evidence)
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPTS_DIR/lib.sh"
COORD_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
LEDGER="$COORD_DIR/ledger"
ACTIVITY="$LEDGER/activity.log"
HEARTBEATS="$LEDGER/heartbeats"

coord_paths || true   # sets ROLE_* for the repos panel; survives any env

cmd="${1:-status}"

if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]; then
  C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[1m'; C_D=$'\e[2m'; C_0=$'\e[0m'
else
  C_R=''; C_G=''; C_Y=''; C_B=''; C_D=''; C_0=''
fi

heartbeat_tail() { # $1=role
  local f="$HEARTBEATS/$1.md"
  if [[ -f "$f" && -s "$f" ]]; then
    echo "  $1: $(tail -n 1 "$f")"
  else
    echo "  $1: (no heartbeat yet)"
  fi
}

lane_is_active() { # lane roles (trailing -N) count as visible only once used
  local r="$1" f
  [[ "$r" =~ -[0-9]+$ ]] || return 0
  [[ -n "$(sess_get "$LEDGER/sessions.json" "$r" 2>/dev/null)" ]] && return 0
  for f in "$LEDGER/messages/$r-"*-out.md; do
    [[ -e "$f" ]] && return 0
  done
  return 1
}

case "$cmd" in
  status)
    echo "${C_B}=== Features ($(date '+%Y-%m-%d %H:%M:%S')) ===${C_0}"
    local_feats=( "$LEDGER"/FEAT-*.md )
    [[ -e "${local_feats[0]}" ]] || echo "  (none)"
    for f in "${local_feats[@]}"; do
      [[ -e "$f" ]] || continue
      title="$(head -n 1 "$f" | sed 's/^# //')"
      status="$(grep -m1 '^- Status:' "$f" | cut -d: -f2- | xargs)"
      updated="$(grep -m1 '^- Updated:' "$f" | cut -d: -f2- | xargs)"
      col="$C_Y"
      case "$status" in
        done|released)       col="$C_G" ;;
        blocked|negotiating) col="$C_R" ;;
      esac
      echo "  $title — ${col}${status}${C_0} ${C_D}(updated $updated)${C_0}"
    done

    echo; echo "=== Role sessions ==="
    if [[ -f "$LEDGER/sessions.json" ]]; then
      sed -n -e 's/^ *"\([a-z0-9-]*\)": "\(sess_[^"]*\)".*/  \1: \2/p' \
             -e 's/^ *"\([a-z0-9-]*\)": null.*/  \1: (no session yet)/p' \
             "$LEDGER/sessions.json"
    fi

    echo; echo "=== In-flight check (transcripts without replies) ==="
    found_inflight=0
    for out in "$LEDGER"/messages/*-out.md; do
      [[ -e "$out" ]] || continue
      reply="${out%-out.md}-reply.md"
      if [[ ! -f "$reply" ]]; then
        found_inflight=1
        st="$(basename "$out" | grep -oE '[0-9]{8}-[0-9]{6}')"
        el="-"
        if [[ "$st" =~ ^([0-9]{8})-([0-9]{6})$ ]]; then
          d="${BASH_REMATCH[1]}"; t="${BASH_REMATCH[2]}"
          ep="$(date -d "${d:0:4}-${d:4:2}-${d:6:2} ${t:0:2}:${t:2:2}:${t:4:2}" +%s 2>/dev/null || true)"
          [[ -n "$ep" ]] && el="$(( ($(date +%s) - ep) / 60 )) min"
        fi
        errf="${out%-out.md}-stderr.log"; out_age="-"
        if [[ -f "$errf" ]]; then
          mt="$(stat -c %Y "$errf" 2>/dev/null || date -r "$errf" +%s 2>/dev/null || echo 0)"
          (( mt > 0 )) && out_age="$(( ($(date +%s) - mt) / 60 )) min"
        fi
        col="$C_Y"
        [[ "${el% min}" =~ ^[0-9]+$ && "${el% min}" -ge 30 ]] && col="$C_R"
        echo "  ${col}RUNNING: $(basename "$out") (started $st, elapsed $el, last output $out_age ago)${C_0}"
        [[ "${out_age% min}" =~ ^[0-9]+$ && "${out_age% min}" -ge 15 ]] && \
          echo "    ${C_R}⚠ silent for ${out_age} — process may be dead; check the orchestrator${C_0}"
      fi
    done
    [[ $found_inflight -eq 0 ]] && echo "  (nothing in flight)"

    echo; echo "=== Last heartbeats ==="
    for r in $ROLES; do lane_is_active "$r" || continue; heartbeat_tail "$r"; done

    echo; echo "=== Recent activity ==="
    [[ -f "$ACTIVITY" ]] && tail -n 15 "$ACTIVITY" || echo "  (activity.log empty)"

    echo; echo "=== Product repos (live git state, snapshot ≤60s old) ==="
    declare -a snap
    for r in $ROLES; do
      lane_is_active "$r" || continue
      name="$r"
      path="$(role_repo "$r")"
      # lane roles work in their isolated worktree, not the shared checkout
      wt="$(role_field "$r" worktree)"
      [[ "$wt" == "auto" ]] && wt="$(dirname "$path")/.orch-worktrees/$r"
      [[ -n "$wt" && -e "$wt/.git" ]] && path="$wt"
      if [[ -e "$path/.git" ]]; then
        mapfile -t snap < <(repo_snapshot "$path")
        d="${snap[1]:-0}"; [[ "$d" =~ ^[0-9]+$ ]] || d=0
        echo "  $name: branch=${snap[0]:--} dirty_files=$d"
      else
        echo "  $name: not a git checkout ($path)"
      fi
    done
    ;;

  live)
    role="${2:-}"
    mkdir -p "$HEARTBEATS"
    touch "$ACTIVITY"
    follow=( "$ACTIVITY" )
    if [[ -n "$role" ]]; then
      f="$HEARTBEATS/$role.md"; touch "$f"; follow+=( "$f" )
    else
      for f in "$HEARTBEATS"/*.md; do [[ -e "$f" ]] && touch "$f" && follow+=( "$f" ); done
    fi
    echo "following: ${follow[*]}  (Ctrl-C to stop)"
    exec tail -f -n 20 "${follow[@]}"
    ;;

  ui)
    interval="${2:-5}"
    interval="${interval//[!0-9]/}"; [[ -n "$interval" ]] || interval=5
    while true; do
      clear 2>/dev/null || printf '\e[2J\e[H'
      bash "$0" status
      [[ "${WATCH_ONCE:-0}" == 1 ]] && break
      printf '\n%s[q]%s quit · any key refreshes · auto-refresh %ss ' "$C_B" "$C_0" "$interval"
      key=""
      read -t "$interval" -n 1 key >/dev/null 2>&1 || true
      [[ "$key" == q || "$key" == Q ]] && { echo; break; }
      sleep 0.3
    done
    ;;

  *)
    echo "usage: scripts/watch.sh status | live [role]" >&2
    exit 1
    ;;
esac
