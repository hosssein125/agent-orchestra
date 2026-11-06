#!/usr/bin/env bash
# dashboard.sh — the colorful menu dashboard for the orchestration.
#
# Full-screen ANSI dashboard with views and a key menu. Pure bash — works
# from Git Bash AND WSL, needs no node.
#
# Keys:  [1] Overview    [2] Features   [3] In-flight   [4] Heartbeats
#        [5] Activity    [6] Repos      [7] Graph (agent topology — the CLI
#                                        twin of the web graph.sh GUI)
#        [i] inspect an agent (opens its ZCode TUI — Git Bash only)
#        [g] web graph  [t] live tail   [r] redraw
#        [+/-] refresh faster/slower    [q] quit
# Env:   DASH_INTERVAL=<sec>   initial refresh rate (default 5)
#        DASH_VIEW=<1-7>        initial view (default 1)
#        DASH_ONCE=1            render one frame and exit (testing)
set -u

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPTS_DIR/lib.sh"
coord_paths || die "cannot locate the projects root (tried F:/Projects, /f/Projects, /mnt/f/Projects)"

LEDGER="$COORD/ledger"
ACTIVITY="$LEDGER/activity.log"
HEARTBEATS="$LEDGER/heartbeats"
MESSAGES="$LEDGER/messages"

if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]; then
  RST=$'\e[0m'; B=$'\e[1m'; DIM=$'\e[2m'
  RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; BLU=$'\e[34m'; MAG=$'\e[35m'; CYN=$'\e[36m'
  HDRBAR=$'\e[44;97;1m'; KEYBAR=$'\e[100;30m'
else
  RST=; B=; DIM=; RED=; GRN=; YEL=; BLU=; MAG=; CYN=; HDRBAR=; KEYBAR=
fi

W="$(tput cols 2>/dev/null || echo 100)"; [[ "$W" =~ ^[0-9]+$ ]] || W=100
(( W > 112 )) && W=112; (( W < 60 )) && W=60
H="${DASH_HEIGHT:-$(tput lines 2>/dev/null || echo 40)}"; [[ "$H" =~ ^[0-9]+$ ]] || H=40
(( H < 20 )) && H=20; (( H > 200 )) && H=200

VIEW="${DASH_VIEW:-1}"
INTERVAL="${DASH_INTERVAL:-5}"; [[ "$INTERVAL" =~ ^[0-9]+$ ]] || INTERVAL=5
VIEWS=(x Overview Features In-flight Heartbeats Activity Repos Graph)

env_label() { case "$(env_kind)" in gitbash) echo "Git Bash";; wsl) echo "WSL";; linux) echo "Linux";; *) echo "?";; esac; }

hr() { local s="" n=$(( W - 6 )); while (( ${#s} < n )); do s="${s}─"; done; printf '  %s%s%s\n' "$DIM" "$s" "$RST"; }
section() { printf '  %s▐ %s%s%s\n' "$CYN" "$B" "$1" "$RST"; }
line()   { printf '  %s\n' "$1"; }

file_age_min() { local f="$1" mt; mt="$(stat -c %Y "$f" 2>/dev/null || date -r "$f" +%s 2>/dev/null || echo 0)"; (( mt > 0 )) && echo $(( ($(date +%s) - mt) / 60 )) || echo 0; }
stamp_age_min() {
  local st="$1" ep=""
  [[ "$st" =~ ^([0-9]{8})-([0-9]{6})$ ]] || { echo 0; return; }
  local d="${BASH_REMATCH[1]}" t="${BASH_REMATCH[2]}"
  ep="$(date -d "${d:0:4}-${d:4:2}-${d:6:2} ${t:0:2}:${t:2:2}:${t:4:2}" +%s 2>/dev/null || true)"
  [[ -n "$ep" ]] && echo $(( ($(date +%s) - ep) / 60 )) || echo 0
}
feat_status_color() { case "$1" in done|released) echo "$GRN";; blocked|negotiating|rolled-back) echo "$RED";; releasing|hotfix-in-flight) echo "$MAG";; *) echo "$YEL";; esac; }

# --- lane visibility: lane roles (trailing -N) appear only once used ---------
lane_is_active() {
  local r="$1" f
  [[ "$r" =~ -[0-9]+$ ]] || return 0          # base roles always visible
  [[ -n "$(sess_get "$LEDGER/sessions.json" "$r" 2>/dev/null)" ]] && return 0
  for f in "$MESSAGES/$r-"*-out.md; do
    [[ -e "$f" ]] && return 0
  done
  return 1
}

# --- views -------------------------------------------------------------------

v_features_lines() {
  local f title status updated col
  local feats=( "$LEDGER"/FEAT-*.md )
  [[ -e "${feats[0]}" ]] || { line "${DIM}(no features yet)${RST}"; return; }
  for f in "${feats[@]}"; do
    [[ -e "$f" ]] || continue
    title="$(head -n 1 "$f" | sed 's/^# //')"
    status="$(grep -m1 '^- Status:' "$f" | cut -d: -f2- | xargs)"
    updated="$(grep -m1 '^- Updated:' "$f" | cut -d: -f2- | xargs)"
    col="$(feat_status_color "$status")"
    line "${B}${title}${RST} — ${col}${status}${RST} ${DIM}(updated ${updated:-?})${RST}"
    grep -m1 '^| 1 |' "$f" 2>/dev/null | cut -c3-100 | while IFS= read -r r; do line "${DIM}request: $(echo "$r" | cut -c9-100)${RST}"; done
    echo
  done
}

v_inflight_lines() {
  local out reply st el age col found=0
  for out in "$MESSAGES"/*-out.md; do
    [[ -e "$out" ]] || continue
    reply="${out%-out.md}-reply.md"
    [[ -f "$reply" ]] && continue
    found=1
    st="$(basename "$out" | grep -oE '[0-9]{8}-[0-9]{6}')"
    el="$(stamp_age_min "$st")"; age="$(file_age_min "${out%-out.md}-stderr.log")"
    col="$YEL"; (( el >= 30 )) && col="$RED"
    line "${col}${B}▶ $(basename "$out")${RST}"
    line "   elapsed ${el} min · last agent output ${age} min ago"
    if (( age >= 15 )); then line "   ${RED}⚠ silent for ${age} min — the process may be dead; check the orchestrator${RST}"; fi
    echo
  done
  (( found == 0 )) && line "${GRN}✓ nothing in flight${RST}"
}

v_heartbeat_lines() {
  local r f n=0
  for r in $ROLES; do
    lane_is_active "$r" || continue
    f="$HEARTBEATS/$r.md"
    line "${MAG}${B}$r${RST}"
    if [[ -s "$f" ]]; then tail -n 10 "$f" | while IFS= read -r l; do line "  ${DIM}·${RST} $(echo "$l" | cut -c1-100)"; done
    else line "  ${DIM}(no heartbeat yet)${RST}"; fi
    echo; n=1
  done
  (( n == 0 )) && line "${DIM}(no heartbeat files)${RST}"
}

v_activity_lines() {
  if [[ -f "$ACTIVITY" ]]; then tail -n 25 "$ACTIVITY" | while IFS= read -r l; do
    case "$l" in *START*) line "${CYN}$l${RST}";; *END*) line "${GRN}$l${RST}";; *FAILED*) line "${RED}$l${RST}";; *) line "$l";; esac
  done
  else line "${DIM}(activity.log empty)${RST}"; fi
}

v_repo_lines() {
  local name path r branch dirty last dcol
  local -a snap
  for r in $ROLES; do
    lane_is_active "$r" || continue
    path="$(role_repo "$r")"
    # lane roles work in their isolated worktree, not the shared checkout
    wt="$(role_field "$r" worktree)"
    [[ "$wt" == "auto" ]] && wt="$(dirname "$path")/.orch-worktrees/$r"
    [[ -n "$wt" && -e "$wt/.git" ]] && path="$wt"
    name="$r"
    if [[ -e "$path/.git" ]]; then
      mapfile -t snap < <(repo_snapshot "$path")
      branch="${snap[0]:--}"; dirty="${snap[1]:-0}"; last="${snap[2]:--}"
      [[ "$dirty" =~ ^[0-9]+$ ]] || dirty=0
      dcol="$GRN"; (( dirty > 0 )) && dcol="$YEL"
      line "${B}${name}${RST}  ${CYN}${branch}${RST}  ${dcol}dirty=${dirty}${RST} ${DIM}(git snapshot ≤60s old)${RST}"
      line "   ${DIM}last: ${last:--}${RST}"
    else
      line "${B}${name}${RST}  ${RED}repo not found${RST} ${DIM}($path)${RST}"
    fi
  done
}

v_overview_lines() {
  section "FEATURES";  v_features_lines
  section "IN-FLIGHT"; v_inflight_lines
  section "LAST HEARTBEAT PER ROLE"
  local r f
  for r in $ROLES; do
    lane_is_active "$r" || continue
    f="$HEARTBEATS/$r.md"
    if [[ -s "$f" ]]; then line "${MAG}$r${RST}: $(tail -n 1 "$f" | cut -c1-95)"
    else line "${MAG}$r${RST}: ${DIM}(no heartbeat yet)${RST}"; fi
  done
  echo
  section "REPOS (live git state)"; v_repo_lines
}

# --- graph view (CLI twin of the web graph.sh topology) -----------------------

node_state_color() { case "$1" in working) echo "$YEL";; idle) echo "$GRN";; none) echo "$DIM";; silent) echo "$RED";; *) echo "$DIM";; esac; }

rep() { local s="" n="$1" c="$2"; while (( ${#s} < n )); do s="$s$c"; done; printf '%s' "$s"; }

pad_ctr() { # center (or truncate+…) text into width $2
  local t="$1" w="$2" p
  if (( ${#t} >= w )); then printf '%.*s…' "$((w-1))" "$t"; return; fi
  p=$(( (w - ${#t}) / 2 ))
  printf '%*s%s%*s' "$p" '' "$t" "$((w - ${#t} - p))" ''
}

graph_role_data() { # $1=role → g_state g_msgs g_out g_hb g_age g_outage
  local role="$1" out st last_disp="" any_inflight=""
  g_sess="$(sess_get "$LEDGER/sessions.json" "$role")"
  g_msgs=0; g_out="-"; g_state="none"; g_hb=""
  for out in "$MESSAGES/$role-"*-out.md; do
    [[ -e "$out" ]] || continue
    # exact role match — a plain prefix glob would also count lane roles
    # sharing the prefix (backend vs backend-2)
    [[ "$(basename "$out")" =~ ^${role}-[0-9]{8}-[0-9]{6}-out\.md$ ]] || continue
    st="$(basename "$out" | grep -oE '[0-9]{8}-[0-9]{6}')"
    [[ -n "$st" ]] && last_disp="$st"
    if [[ -f "${out%-out.md}-reply.md" ]]; then g_msgs=$((g_msgs+1))
    else any_inflight="$st"; fi
  done
  [[ -n "$last_disp" ]] && g_out="$(echo "$last_disp" | sed -n 's/^\(....\)\(..\)\(..\)-\(..\)\(..\).*$/\4:\5/p')"
  local f="$HEARTBEATS/$role.md"
  [[ -s "$f" ]] && g_hb="$(tail -n 1 "$f" | sed 's/^[0-9-]* [0-9:]* | //' | tr -d '\r')"
  g_age=0; g_outage=0
  if [[ -n "$g_sess" ]]; then
    g_state="idle"
    if [[ -n "$any_inflight" ]]; then
      g_state="working"; g_age="$(stamp_age_min "$any_inflight")"
      local errf="$MESSAGES/$role-$any_inflight-stderr.log"
      [[ -f "$errf" ]] && g_outage="$(file_age_min "$errf")"
      (( g_outage >= 15 )) && g_state="silent"
    fi
  fi
}

v_graph_lines() {
  local -a roles=()
  local r hidden=0
  for r in $ROLES; do
    if lane_is_active "$r"; then roles+=( "$r" ); else hidden=$((hidden+1)); fi
  done
  local n=${#roles[@]}
  local -A st msgs outr hb age outage
  local nwork=0 nfeat=0
  local ff=( "$LEDGER"/FEAT-*.md ); [[ -e "${ff[0]}" ]] && nfeat=${#ff[@]}
  for r in "${roles[@]}"; do
    graph_role_data "$r"
    st[$r]="$g_state"
    msgs[$r]=$g_msgs; outr[$r]="$g_out"; hb[$r]="$g_hb"
    age[$r]=$g_age; outage[$r]=$g_outage
    [[ "${st[$r]}" == working || "${st[$r]}" == silent ]] && nwork=$((nwork+1))
  done
  (( W < 96 )) && line "${DIM}(terminal narrower than 96 cols — the graph may wrap; widen the window)${RST}"

  # layout: 30-wide agent boxes, 3-gap; orchestrator box centered over the
  # middle agent's connector column (box centers at left + 14).
  local bw=30 gap=3
  local i c mid=$(( (n-1)/2 ))
  local -a centers=()
  for ((i=0; i<n; i++)); do centers[i]=$(( i*(bw+gap) + 14 )); done
  local m="${centers[$mid]}"

  # orchestrator box: 30 wide with its ┬ at column m (+3 matches box indent)
  printf '%*s%s\n' "$(( m-11 ))" '' "${CYN}┌$(rep 28 ─)┐${RST}"
  printf '%*s%s\n' "$(( m-11 ))" '' "${CYN}│${RST}${B}$(pad_ctr 'ORCHESTRATOR' 28)${RST}${CYN}│${RST}"
  printf '%*s%s\n' "$(( m-11 ))" '' "${CYN}│${RST}$(pad_ctr "$nwork talking · $nfeat feature(s)" 28)${CYN}│${RST}"
  printf '%*s%s\n' "$(( m-11 ))" '' "${CYN}└$(rep 13 ─)┬$(rep 14 ─)┘${RST}"
  # bridge + box rows print below, after the boxes are built

  local build_box='
    c="$(node_state_color "${st[$r]}")"
    case "${st[$r]}" in
      working) st_txt="● WORKING (${age[$r]}m)" ;;
      idle)    st_txt="● IDLE — waiting" ;;
      none)    st_txt="○ WAITING — no session" ;;
      silent)  st_txt="● SILENT ${outage[$r]}m (!)" ;;
    esac
    meta="msgs ${msgs[$r]} · out ${outr[$r]}"
    printf "%s\n%s\n%s\n%s\n%s\n%s\n" \
      "${c}┌$(rep 13 ─)┴$(rep 14 ─)┐${RST}" \
      "│${B}$(pad_ctr "$r" 28)${RST}│" \
      "│${c}$(pad_ctr "$st_txt" 28)${RST}│" \
      "│${DIM}$(pad_ctr "$meta" 28)${RST}│" \
      "│${DIM}$(pad_ctr "${hb[$r]}" 28)${RST}│" \
      "${c}└$(rep 28 ─)┘${RST}"
  '
  local -a boxes=()
  local -a brow
  for r in "${roles[@]}"; do
    mapfile -t brow < <(eval "$build_box")
    boxes+=( "${brow[@]}" )
  done
  # rows of up to 4 boxes; each row gets its own bridge (lane topologies —
  # roots + activated lanes — can exceed one row)
  local per=4 k j row b e i2 prev bridge
  (( n > per )) && printf '%*s%s%s\n' "$(( m + 3 ))" '' "${DIM}│${RST}"
  for ((b=0; b<n; b+=per)); do
    e=$(( b + per )); (( e > n )) && e=$n
    bridge=""; prev=""
    for ((i2=b; i2<e; i2++)); do
      c="${centers[$i2]}"
      if [[ $i2 -eq $b ]]; then
        bridge+="$(printf '%*s' "$c" '')┌"
      else
        bridge+="$(rep $(( c - prev - 1 )) ─)"
        if [[ $i2 -eq $(( e-1 )) ]]; then bridge+="┐"; else bridge+="┼"; fi
      fi
      prev="$c"
    done
    printf '   %s%s%s\n' "$DIM" "$bridge" "$RST"
    for ((k=0; k<6; k++)); do
      row=""
      for ((j=b; j<e; j++)); do
        row+="${row:+   }${boxes[$(( j*6 + k ))]}"
      done
      line "   $row"
    done
    echo
  done
  echo
  line "${DIM}● WORKING amber · ● IDLE green · ○ no session · SILENT red = in-flight but quiet ${RST}"
  (( hidden > 0 )) && line "${DIM}$hidden declared lane agent(s) not yet activated (hidden until first dispatch)${RST}"
  line "${DIM}press [g] for the animated web version of this graph (graph.sh)${RST}"
}

# --- chrome -------------------------------------------------------------------

draw_header() {
  local right="$(printf '%s · %s · %s' "${VIEWS[$VIEW]}" "$(date '+%H:%M:%S')" "$(env_label)")"
  local left=" ${PROJECT_NAME:-ORCH} ORCHESTRATION "
  local pad=$(( W - ${#left} - ${#right} - 1 )); (( pad < 1 )) && pad=1
  printf '%s%s%*s%s%s%s\n' "$HDRBAR" "$left" "$pad" '' "$right" ' ' "$RST"
}

draw_footer() {
  local keys=' [1]Overview [2]Features [3]In-flight [4]Beats [5]Activity [6]Repos [7]Graph [i]inspect [g]web [t]ail [+/−]speed [r]redraw [q]uit '
  printf '%s%.*s%s\n' "$KEYBAR" "$W" "$keys" "$RST"
}

# --- actions --------------------------------------------------------------------

pick_and_inspect() {
  clear 2>/dev/null || printf '\e[2J\e[H'
  local -a roles=()
  local r0
  for r0 in $ROLES; do lane_is_active "$r0" && roles+=( "$r0" ); done
  (( ${#roles[@]} > 9 )) && roles=( "${roles[@]:0:9}" )   # single-digit menu
  local n=${#roles[@]} menu="" i
  for ((i=0; i<n; i++)); do menu+=" [$((i+1))] ${roles[$i]}"; done
  printf 'Inspect which agent in the ZCode TUI?\n\n%s   [Esc] cancel\n' "$menu"
  local k=""; IFS= read -t 30 -n 1 k || return 0
  case "$k" in
    [1-9]) [[ $k -le $n ]] && k="${roles[$((k-1))]}" || return 0 ;;
    *) return 0 ;;
  esac
  clear 2>/dev/null || printf '\e[2J\e[H'
  bash "$SCRIPTS_DIR/inspect.sh" "$k" || { printf '\n(press any key)'; IFS= read -t 30 -n 1 _x || true; }
  printf '\n(press any key to return to the dashboard)'; IFS= read -t 30 -n 1 _x || true
}

# --- main loop --------------------------------------------------------------------

render_view() {
  case "$1" in
    1) v_overview_lines ;;
    2) v_features_lines ;;
    3) v_inflight_lines ;;
    4) v_heartbeat_lines ;;
    5) v_activity_lines ;;
    6) v_repo_lines ;;
    7) v_graph_lines ;;
  esac
}

while :; do
  # build the whole frame off-screen first (git snapshots can take a while on
  # /mnt/f) — then clear + print atomically, so the screen never half-draws
  body="$(render_view "$VIEW")"
  local_max=$(( H - 6 ))
  view_n="$(printf '%s\n' "$body" | wc -l | tr -d ' ')"
  if (( view_n > local_max )); then
    body="$(printf '%s\n' "$body" | head -n "$((local_max - 1))"
            line "${DIM}… $((view_n - local_max + 1)) more lines — switch view ([1]-[7]) or a taller window${RST}")"
  fi
  frame="$(draw_header; echo; printf '%s\n' "$body"; echo; hr; draw_footer)"
  clear 2>/dev/null || printf '\e[2J\e[H'
  printf '%s\n' "$frame"
  [[ "${DASH_ONCE:-0}" == 1 ]] && break

  key=""
  IFS= read -t "$INTERVAL" -n 1 key || true
  case "$key" in
    [1-7]) VIEW="$key" ;;
    q|Q) break ;;
    r|R) : ;;
    '+'|'=') (( INTERVAL > 1 )) && INTERVAL=$(( INTERVAL - 1 )) ;;
    '-') (( INTERVAL < 60 )) && INTERVAL=$(( INTERVAL + 1 )) ;;
    i|I) pick_and_inspect ;;
    g|G) msg="$(bash "$SCRIPTS_DIR/graph.sh" --bg 2>&1)" || msg="  graph GUI failed to start (try: bash scripts/graph.sh)"
         echo "  $msg"
         IFS= read -t 3 -n 1 _x || true ;;
    t|T) clear; bash "$SCRIPTS_DIR/watch.sh" live; printf '\n(press any key to return)'; IFS= read -t 30 -n 1 _x || true ;;
    $'\e') IFS= read -t 0.2 -n 2 _rest || true ;;
  esac
done
