#!/usr/bin/env bash
# relay.sh — send a message to a role-agent session (headless zcode CLI).
#
# The orchestrator NEVER edits the product repos directly. It talks to role
# agents: persistent ZCode sessions rooted in their own repo (--cwd), so each
# agent natively loads that repo's AGENTS.md, skills, and git hooks.
#
# Usage:
#   scripts/relay.sh <role> [options] <message ...>
#
#     role            backend | admin-front | customer-front
#     -f <file>       attach a ledger/feature file to the message
#     -m <mode>       permission mode: build|edit|plan|yolo (default yolo —
#                     non-interactive runs need auto-approval)
#     --task <id>     task id tracked in ledger/tasks.json (default: inferred
#                     from a -f FEAT-*.md attach) — movements are logged so
#                     the graph GUI can animate the task between nodes
#     --why "<text>"  one-line reason for this dispatch (shown as the move
#                     reason in the task history; default: message head)
#     --salvage      prepend the R17 notice — use on EVERY re-dispatch after
#                     a dead relay: tells the session partial work may exist
#                     on the branch and it must audit and salvage first
#     @<path>         token inside <message>: attach that file
#     --force         override the one-in-flight-per-role guard (R19)
#     --dry-run       build the relay and print it, send nothing
#     --check         validate setup only (CLI, node, repos, registry); send nothing
#
# Every relay is transcripted to ledger/messages/<role>-<stamp>-out.md /
# -reply.md (plus the raw JSON envelope). The reply text is echoed on stdout.
# The role's sessionId is created on first use and resumed thereafter
# (ledger/sessions.json is the registry).
#
# Feature implementations run long: launch this script in the background
# (run_in_background / `&`) and collect the reply file when it exits.
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COORD_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
source "$SCRIPTS_DIR/lib.sh"
ZCODE_CLI="${ZCODE_CLI:-$(find_cli || echo C:/Users/Hossein/AppData/Local/Programs/ZCode/resources/glm/zcode.cjs)}"
SESSIONS_FILE="$COORD_DIR/ledger/sessions.json"
MESSAGES_DIR="$COORD_DIR/ledger/messages"
ACTIVITY_FILE="$COORD_DIR/ledger/activity.log"
TASKS_FILE="$COORD_DIR/ledger/tasks.json"

# task_log <from> <to> <why> — append a task movement to ledger/tasks.json
# (the graph GUI animates tasks between nodes from this log). Best-effort:
# never fails the relay; skipped entirely when no task id is known.
task_log() {
  [[ -n "${TASK_ID:-}" && -n "${node_bin:-}" ]] || return 0
  "$node_bin" -e '
    const fs=require("fs");
    const [f,id,title,from,to,why]=process.argv.slice(1);
    let j={};try{j=JSON.parse(fs.readFileSync(f,"utf8"))}catch(e){}
    const n=new Date(),p=x=>String(x).padStart(2,"0");
    const t=n.getFullYear()+"-"+p(n.getMonth()+1)+"-"+p(n.getDate())+" "+p(n.getHours())+":"+p(n.getMinutes());
    if(!j[id])j[id]={title:title||id,status:"active",created:t,holder:"orchestrator",history:[]};
    j[id].history.push({t:t,from:from,to:to,why:String(why||"").replace(/\s+/g," ").slice(0,140)});
    j[id].holder=to;j[id].updated=t;
    fs.writeFileSync(f,JSON.stringify(j,null,2)+"\n");
  ' "$TASKS_FILE" "$TASK_ID" "${TASK_TITLE:-}" "$1" "$2" "$3" >/dev/null 2>&1 || true
  return 0
}

coord_paths || die "no orchestration.json found — define one with scripts/init.sh --here (or scaffold a workspace with --target)"

role=""
mode="yolo"
TASK_ID=""
TASK_WHY=""
declare -a attaches=() message=()

usage() { sed -n '2,34p' "$0"; exit "${1:-0}"; }

# --- parse args -------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)   echo "== relay.sh setup check =="; CHECK=1; shift ;;
    --force)   FORCE_RELAY=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --task)    TASK_ID="$2"; shift 2 ;;
    --why)     TASK_WHY="$2"; shift 2 ;;
    --salvage) SALVAGE=1; shift ;;
    -f)        attaches+=("$2"); shift 2 ;;
    -m)        mode="$2"; shift 2 ;;
    -h|--help) usage 0 ;;
    *)         if [[ -z "$role" ]]; then role="$1"; else message+=("$1"); fi; shift ;;
  esac
done

node_bin="$(find_node || true)"

# --- task tracking (ledger/tasks.json — feeds the graph GUI) -------------------
# Task id: explicit --task, else inferred from a FEAT-*.md attach; title from
# the FEAT heading. Movements are logged automatically at dispatch/reply/fail.
if [[ -z "$TASK_ID" ]]; then
  for a in "${attaches[@]}"; do
    b="$(basename "$a")"
    [[ "$b" =~ ^(FEAT-[0-9]{8}-.+)\.md$ ]] && { TASK_ID="${BASH_REMATCH[1]}"; break; }
  done
fi
TASK_TITLE="$TASK_ID"
if [[ -n "$TASK_ID" ]]; then
  for a in "${attaches[@]}"; do
    [[ "$(basename "$a")" == "$TASK_ID.md" && -f "$a" ]] && { TASK_TITLE="$(head -n 1 "$a" | sed 's/^# //')"; break; }
  done
fi

# --- --check: validate and exit ----------------------------------------------
if [[ "${CHECK:-0}" == 1 ]]; then
  fail=0
  [[ -n "$node_bin" ]] && echo "node:            OK ($node_bin)" || { echo "node:            MISSING (set ZCODE_NODE)"; fail=1; }
  [[ -f "$ZCODE_CLI" ]] && echo "zcode CLI:       OK ($ZCODE_CLI)" || { echo "zcode CLI:       MISSING ($ZCODE_CLI — override with ZCODE_CLI)"; fail=1; }
  for r in $ROLES; do
    path="$(role_repo "$r")"
    h="$(role_field "$r" harness)"; [[ -n "$h" ]] || h="$HARNESS_DEFAULT"
    bin=""
    case "$h" in
      zcode) [[ -n "$(find_cli 2>/dev/null || true)" ]] && bin="ok" ;;
      claude|codex|*) b="$(harness_bin "$h" 2>/dev/null || true)"
                      { [[ -n "$b" ]] && { command -v "$b" >/dev/null 2>&1 || [[ -x "$b" ]]; }; } && bin="ok" ;;
    esac
    if [[ -d "$path" && "$bin" == "ok" ]]; then
      echo "repo $r: OK (harness $h)"
    elif [[ -d "$path" ]]; then
      echo "repo $r: OK (harness $h — BIN MISSING)"; fail=1
    else
      echo "repo $r: MISSING ($path)"; fail=1
    fi
  done
  if [[ -f "$SESSIONS_FILE" ]]; then
    [[ -n "$node_bin" ]] || { echo "sessions.json:   (node unavailable to validate)"; fail=1; }
    "$node_bin" -e "JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'))" "$SESSIONS_FILE" \
      && echo "sessions.json:   OK" || { echo "sessions.json:   INVALID JSON"; fail=1; }
  else
    echo "sessions.json:   MISSING ($SESSIONS_FILE)"
  fi
  [[ $fail -eq 0 ]] && echo "ALL CHECKS PASSED" || echo "CHECKS FAILED"
  exit $fail
fi

[[ -n "$role" ]] || { echo "error: role required (one of: $(echo "$ROLES" | tr ' ' '|'))" >&2; usage 1; }

repo="$(role_repo "$role")" || { echo "error: unknown role '$role' (known: $(echo "$ROLES" | tr ' ' '|'))" >&2; exit 1; }

# --- guard rails -------------------------------------------------------------
require_gitbash   # relays drive the Windows ZCode CLI + its session store
[[ -n "$node_bin" ]] || { echo "error: node not found on PATH or common locations — set ZCODE_NODE" >&2; exit 1; }
[[ -f "$ZCODE_CLI" ]] || { echo "error: zcode CLI not found at $ZCODE_CLI (override with ZCODE_CLI)" >&2; exit 1; }
[[ -d "$repo" ]] || { echo "error: repo for role '$role' not found: $repo" >&2; exit 1; }
mkdir -p "$MESSAGES_DIR"
# the relay owns the session registry — create it on first use
[[ -f "$SESSIONS_FILE" ]] || printf '{}\n' > "$SESSIONS_FILE"

# --- R2/R19 guard: one in-flight relay per role --------------------------------
# An un-replied dispatch for this role blocks a new one — dead or alive.
# A dead dispatch must first be marked orphaned (write its -reply.md marker)
# so in-flight detection stays truthful; FORCE_RELAY=1 overrides knowingly.
if [[ "${FORCE_RELAY:-0}" != 1 ]]; then
  for out in "$MESSAGES_DIR/$role-"*-out.md; do
    [[ -e "$out" ]] || continue
    if [[ ! -f "${out%-out.md}-reply.md" ]]; then
      echo "error: '$role' already has an in-flight dispatch: $(basename "$out")" >&2
      echo "       One relay per role at a time (R2/R19). If it is dead, mark it orphaned:" >&2
      echo "       write ${out%-out.md}-reply.md — or re-run with --force." >&2
      exit 1
    fi
  done
fi

# expand @file tokens from the message into attachments
msg_words=()
for w in "${message[@]}"; do
  if [[ "$w" == @* ]]; then
    p="${w#@}"
    [[ -f "$p" ]] || { echo "error: attach file not found: $p" >&2; exit 1; }
    attaches+=("$p")
  else
    msg_words+=("$w")
  fi
done
msg="${msg_words[*]}"
if [[ -z "$msg" && ${#attaches[@]} -gt 0 ]]; then
  msg="Read the attached file(s) and act on them."
fi
[[ -n "$msg" ]] || { echo "error: empty message" >&2; usage 1; }

# R17 salvage notice: mandatory on re-dispatch after a dead relay — the new
# session must audit the branch for the dead agent's partial work first.
if [[ "${SALVAGE:-0}" == 1 ]]; then
  msg="A PREVIOUS ATTEMPT DIED MID-WORK: committed or uncommitted partial work may already exist on your branch — AUDIT AND SALVAGE it before redoing anything (the attempt's transcript and your heartbeat file are in the coordination ledger). $msg"
  [[ -z "${TASK_WHY:-}" ]] && TASK_WHY="salvage re-dispatch after dead relay (R17)"
fi

sess="$(sess_get "$SESSIONS_FILE" "$role")"

stamp="$(date +%Y%m%d-%H%M%S)"
out_file="$MESSAGES_DIR/$role-$stamp-out.md"
reply_file="$MESSAGES_DIR/$role-$stamp-reply.md"
json_file="$MESSAGES_DIR/$role-$stamp.json"
err_file="$MESSAGES_DIR/$role-$stamp-stderr.log"

# --- harness resolution (multi-harness: zcode | claude | codex | custom) -------
# Per-role "harness"/"model"/"args" fields in orchestration.json; default is
# harness_default (zcode). Every harness shares the same contract: transcript
# out/reply, raw envelope on disk, session id recorded, task movement logged.
HARNESS="$(role_field "$role" harness)"
[[ -n "$HARNESS" ]] || HARNESS="$HARNESS_DEFAULT"
ROLE_MODEL="$(role_field "$role" model)"
ROLE_ARGS="$(role_field "$role" args)"

# --- optional per-role worktree isolation (parallel same-repo work, R2 hatch) --
# "worktree": "auto" → <repo>/../.orch-worktrees/<role>, or an explicit path.
# Created once off the repo's current HEAD on branch orch/<role>, reused after.
DISPATCH_CWD="$repo"
WT="$(role_field "$role" worktree)"
if [[ -n "$WT" ]]; then
  wt_path="$WT"; [[ "$wt_path" == "auto" ]] && wt_path="$(dirname "$repo")/.orch-worktrees/$role"
  if [[ ! -e "$wt_path/.git" ]]; then
    git -C "$repo" worktree add -b "orch/$role" "$wt_path" > "$MESSAGES_DIR/$role-$stamp-worktree.log" 2>&1 \
      || die "cannot create worktree $wt_path for '$role' (see $MESSAGES_DIR/$role-$stamp-worktree.log)"
  fi
  DISPATCH_CWD="$wt_path"
fi

# prompt: zcode carries attaches natively; other harnesses get them inlined
prompt="$msg"
if [[ "$HARNESS" != "zcode" && ${#attaches[@]} -gt 0 ]]; then
  prompt="$msg"$'\n'
  for a in "${attaches[@]}"; do prompt+=$'\n'"--- FILE: $a ---"$'\n'"$(cat "$a")"$'\n'; done
fi

# --- build the harness command line -------------------------------------------
HARGS=()
case "$HARNESS" in
  zcode)
    HARGS=( -p "$msg" --cwd "$DISPATCH_CWD" --mode "$mode" --json )
    [[ -n "$sess" ]] && HARGS+=( --resume "$sess" )
    [[ -n "$ROLE_MODEL" ]] && HARGS+=( --model "$ROLE_MODEL" )
    for a in "${attaches[@]}"; do HARGS+=( --attach "$a" ); done
    ;;
  claude)
    HARGS=( -p "$prompt" --output-format json )
    case "$mode" in
      yolo)  HARGS+=( --dangerously-skip-permissions ) ;;
      build) HARGS+=( --permission-mode acceptEdits ) ;;
      plan)  HARGS+=( --permission-mode plan ) ;;
    esac
    [[ -n "$sess" ]] && HARGS+=( --resume "$sess" )
    [[ -n "$ROLE_MODEL" ]] && HARGS+=( --model "$ROLE_MODEL" )
    if [[ -n "$ROLE_ARGS" ]]; then read -r -a _extra <<< "$ROLE_ARGS"; HARGS+=( "${_extra[@]}" ); fi
    ;;
  codex)
    if [[ -n "$sess" ]]; then HARGS=( exec resume "$sess" --json ); else HARGS=( exec --json ); fi
    HARGS+=( --cd "$DISPATCH_CWD" )
    case "$mode" in
      yolo)  HARGS+=( --full-auto ) ;;
      build) HARGS+=( --sandbox workspace-write ) ;;
      plan|edit) HARGS+=( --sandbox read-only ) ;;
    esac
    [[ -n "$ROLE_MODEL" ]] && HARGS+=( -m "$ROLE_MODEL" )
    if [[ -n "$ROLE_ARGS" ]]; then read -r -a _extra <<< "$ROLE_ARGS"; HARGS+=( "${_extra[@]}" ); fi
    HARGS+=( "$prompt" )
    ;;
  *)
    CLI_BIN="$(harness_bin "$HARNESS")" \
      || die "unknown harness '$HARNESS' — define \"harnesses\": {\"$HARNESS\": {\"bin\": \"…\"}} in orchestration.json"
    if [[ -n "$ROLE_ARGS" ]]; then read -r -a _extra <<< "$ROLE_ARGS"; HARGS+=( "${_extra[@]}" ); fi
    HARGS+=( "$prompt" )
    ;;
esac

if [[ "${DRY_RUN:-0}" == 1 ]]; then
  # exits BEFORE any transcript is written — a dry run must not leave a
  # dangling -out.md that would read as an in-flight dispatch (R19)
  echo "DRY RUN — would relay to $role (harness $HARNESS, session ${sess:-new}, mode $mode, cwd $DISPATCH_CWD):"
  case "$HARNESS" in
    zcode)  printf ' %q' "$node_bin" "$ZCODE_CLI" "${HARGS[@]}"; echo ;;
    claude) printf ' %q' "$(harness_bin claude)" "${HARGS[@]}"; echo "   (cwd $DISPATCH_CWD)" ;;
    codex)  printf ' %q' "$(harness_bin codex)" "${HARGS[@]}"; echo ;;
    *)      printf ' %q' "$CLI_BIN" "${HARGS[@]}"; echo "   (cwd $DISPATCH_CWD)" ;;
  esac
  echo "message: $msg"
  exit 0
fi

# --- transcript the outgoing message ----------------------------------------
{
  echo "# -> $role  ($stamp)"
  echo "- session: ${sess:-<new>}"
  echo "- harness: $HARNESS"
  echo "- mode: $mode"
  echo "- repo: $repo${WT:+ (worktree: $wt_path)}"
  [[ ${#attaches[@]} -gt 0 ]] && printf -- '- attach: %s\n' "${attaches[@]}"
  echo
  echo "## Message"
  echo
  echo "$msg"
} > "$out_file"

start_ts=$(date +%s)
echo "$(date '+%Y-%m-%d %H:%M:%S') | START  | $role | ${sess:-new session} | mode=$mode harness=$HARNESS | $(basename "$out_file")" >> "$ACTIVITY_FILE"
ORCH_ROLE="$role" ORCH_REPO="$repo" ORCH_MODE="$mode" ORCH_OUT_FILE="$out_file" \
ORCH_JSON_FILE="$json_file" ORCH_SESSION="${sess:-new}" \
  run_hooks on-start
task_log orchestrator "$role" "${TASK_WHY:-dispatch: $msg}"

set +e
case "$HARNESS" in
  zcode)  "$node_bin" "$ZCODE_CLI" "${HARGS[@]}" > "$json_file" 2> "$err_file"; rc=$? ;;
  claude) cb="$(harness_bin claude)"; ( cd "$DISPATCH_CWD" && "$cb" "${HARGS[@]}" ) > "$json_file" 2> "$err_file"; rc=$? ;;
  codex)  xb="$(harness_bin codex)";  ( cd "$DISPATCH_CWD" && "$xb" "${HARGS[@]}" ) > "$json_file" 2> "$err_file"; rc=$? ;;
  *)      ( cd "$DISPATCH_CWD" && "$CLI_BIN" "${HARGS[@]}" ) > "$json_file" 2> "$err_file"; rc=$? ;;
esac
set -e

if [[ $rc -ne 0 ]]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') | FAILED | $role | rc=$rc | $(basename "$json_file")" >> "$ACTIVITY_FILE"
  echo "error: $HARNESS CLI exited $rc — see $err_file" >&2
  ORCH_ROLE="$role" ORCH_REPO="$repo" ORCH_RC="$rc" \
  ORCH_OUT_FILE="$out_file" ORCH_JSON_FILE="$json_file" \
  ORCH_STDERR_FILE="$err_file" \
    run_hooks on-fail
  task_log "$role" orchestrator "dispatch failed (rc=$rc) — stderr kept beside the transcript"
  exit $rc
fi

# --- parse the envelope (shared tolerant decoder: zcode/claude/codex shapes) ---
parsed="$("$node_bin" "$SCRIPTS_DIR/envelope.js" "$json_file" --full)" \
  || { echo "error: could not parse $HARNESS output — see $json_file" >&2; exit 1; }
_head="$(printf '%s' "$parsed" | head -n1)"          # sess\tin\tout\t<first reply line>
new_sess="$(printf '%s' "$_head" | cut -f1)"
tin="$(printf '%s' "$_head" | cut -f2)"
tout="$(printf '%s' "$_head" | cut -f3)"
reply="$(printf '%s' "$parsed" | cut -f4-)"
tokens="tokens in=$tin out=$tout"

dur=$(( $(date +%s) - start_ts ))
echo "$(date '+%Y-%m-%d %H:%M:%S') | END    | $role | $new_sess | ${dur}s | $tokens" >> "$ACTIVITY_FILE"

{
  echo "# <- $role  ($stamp)"
  echo "- session: $new_sess"
  echo
  echo "$reply"
} > "$reply_file"

# record/refresh the session id (absent session ids are tolerated — the
# harness may not report one; the previous id stays registered)
if [[ -n "$new_sess" && "$new_sess" != "?" ]]; then
  node -e "
const fs=require('fs');
const f=process.argv[1], role=process.argv[2], sess=process.argv[3];
const s=JSON.parse(fs.readFileSync(f,'utf8'));
if(s[role]!==sess){s[role]=sess;fs.writeFileSync(f,JSON.stringify(s,null,2)+'\n');}
" "$SESSIONS_FILE" "$role" "$new_sess"
fi

# notify hooks (best-effort; see hooks/README.md)
ORCH_ROLE="$role" ORCH_REPO="$repo" ORCH_SESSION="$new_sess" ORCH_DURATION="$dur" \
ORCH_TOKENS_IN="$(printf '%s' "$tokens" | sed -n 's/.*in=\([0-9]*\).*/\1/p')" \
ORCH_TOKENS_OUT="$(printf '%s' "$tokens" | sed -n 's/.*out=\([0-9]*\).*/\1/p')" \
ORCH_OUT_FILE="$out_file" ORCH_REPLY_FILE="$reply_file" ORCH_JSON_FILE="$json_file" \
  run_hooks on-reply

# task movement: the task comes home with the reply's first line as the reason
rwhy="$(printf '%s\n' "$reply" | awk 'NF{sub(/^[ \t]+/,"");print;exit}' | cut -c1-140)"
task_log "$role" orchestrator "${rwhy:-replied (see transcript)}"

# optional auto-commit of the ledger after every reply ("auto_commit": true
# or ORCH_AUTO_COMMIT=1) — the audit trail stays pushed without ceremony
if [[ "${ORCH_AUTO_COMMIT:-0}" == 1 ]] || grep -q '^  "auto_commit": true' "$(orch_config)" 2>/dev/null; then
  if git -C "$COORD_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$COORD_DIR" add -A ledger orchestration.json >/dev/null 2>&1 || true
    git -C "$COORD_DIR" diff --cached --quiet >/dev/null 2>&1 || \
      git -C "$COORD_DIR" commit -q -m "orch(auto): $role replied ($stamp)" >/dev/null 2>&1 || true
  fi
fi

echo "$reply"
