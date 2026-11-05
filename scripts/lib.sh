#!/usr/bin/env bash
# lib.sh — shared helpers for the coordination scripts.
# Pure bash; no node required for anything in this file.

# --- environment --------------------------------------------------------------

env_kind() {
  local o
  o="$(uname -o 2>/dev/null || uname -s 2>/dev/null || echo unknown)"
  case "$o" in
    Msys*|Cygwin*) echo "gitbash" ;;
    GNU/Linux*)
      if grep -qi microsoft /proc/version 2>/dev/null; then echo "wsl"
      else echo "linux"; fi ;;
    *) echo "other" ;;
  esac
}

# --- projects root (optional override for finding sibling repos) ---------------

projects_root() {
  local c
  for c in "${ORCH_PROJECTS:-}" "F:/Projects" "/f/Projects" "/mnt/f/Projects"; do
    [[ -n "$c" && -d "$c" ]] && { echo "$c"; return 0; }
  done
  return 1
}

# --- orchestration config ------------------------------------------------------

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COORD_DIR_LIB="$(cd "$LIB_DIR/.." && pwd)"
declare -A ROLE_CFG_LINE=() HARNESS_BIN=()

orch_config() { echo "${ORCH_CONFIG:-$COORD_DIR_LIB/orchestration.json}"; }

# load_roles — resolve role→repo mapping + per-role harness settings.
# Source of truth: orchestration.json next to the scripts (written by
# scripts/init.sh, format is machine-stable so pure bash can parse it).
# Two role forms are supported, one line each:
#     "backend": "F:/repos/api",                       ← simple
#     "review":  {"repo": "F:/repos/api", "harness": "codex", "model": "m",
#                 "worktree": "auto", "args": "--sandbox workspace-write"},
# Without a config file this fails: a fresh clone must run
# `scripts/init.sh --here` (or scaffold a workspace with --target) first.
# Sets: PROJECT_NAME ROLES ROLE_<NAME> OVERLAP_AXES CONTRACT_NOTE_ROOT
#       HARNESS_DEFAULT ROLE_CFG_LINE[] HARNESS_BIN[]
load_roles() {
  PROJECT_NAME="orchestration"
  OVERLAP_AXES=""
  CONTRACT_NOTE_ROOT="Docs/frontend"
  HARNESS_DEFAULT="zcode"
  local cfg
  cfg="$(orch_config)"
  [[ -f "$cfg" ]] || return 1
  PROJECT_NAME="$(sed -n 's/^  "project": "\([^"]*\)".*/\1/p' "$cfg" | head -n1)"
  HARNESS_DEFAULT="$(sed -n 's/^  "harness_default": "\([^"]*\)".*/\1/p' "$cfg" | head -n1)"
  [[ -n "$HARNESS_DEFAULT" ]] || HARNESS_DEFAULT="zcode"
  ROLES=""
  local block name rest buf depth o c
  # brace-aware parse of the roles block: role values are either
  # "name": "path"  or  "name": { …possibly across lines… }
  block="$(sed -n '/^  "roles": {/,/^  },\{0,1\}$/p' "$cfg" | sed '1d;$d')"
  name=""; buf=""; depth=0
  while IFS= read -r line; do
    line="${line%$'\r'}"
    if (( depth == 0 )); then
      name="$(printf '%s' "$line" | sed -n 's/^  *"\([A-Za-z0-9_-]*\)":.*/\1/p')"
      [[ -z "$name" ]] && continue
      rest="$(printf '%s' "$line" | sed 's/^  *"[A-Za-z0-9_-]*": *//')"
      o="$(printf '%s' "$rest" | tr -cd '{' | wc -c)"
      c="$(printf '%s' "$rest" | tr -cd '}' | wc -c)"
      if [[ "$rest" == \{* && "$o" != "$c" ]]; then
        buf="$rest"; depth=$(( o - c ))    # multi-line object — keep consuming
      else
        buf="$rest"; depth=0               # complete on this line
      fi
    else
      o="$(printf '%s' "$line" | tr -cd '{' | wc -c)"
      c="$(printf '%s' "$line" | tr -cd '}' | wc -c)"
      buf="$buf $line"; depth=$(( depth + o - c ))
    fi
    if (( depth == 0 )) && [[ -n "$name" ]]; then
      ROLE_CFG_LINE[$name]="$buf"
      ROLES="${ROLES:+$ROLES }$name"
      name=""
    fi
  done <<< "$block"
  [[ -n "$ROLES" ]] || return 1
  OVERLAP_AXES="$(sed -n 's/^  "overlap_axes": \[\(.*\)\].*/\1/p' "$cfg" | head -n1 | sed 's/", "/ · /g; s/"//g')"
  CONTRACT_NOTE_ROOT="$(sed -n 's/^  "contract_note_root": "\([^"]*\)".*/\1/p' "$cfg" | head -n1)"
  # optional harness bin overrides, indent-tolerant:
  #   "harnesses": { "claude": { "bin": "C:/…" } }
  local hp
  hp="$(awk '/^  "harnesses": {/{inh=1;next} inh&&/^  },?$/{inh=0} inh{
      if (match($0,/^    "[A-Za-z0-9_-]+":/)) { name=$0; sub(/^ *"/,"",name); sub(/".*/,"",name) }
      if (match($0,/"bin": *"[^"]*"/)) { b=$0; sub(/^.*"bin": *"/,"",b); sub(/".*$/,"",b); print name "\t" b }
    }' "$cfg")"
  while IFS=$'\t' read -r hn hb; do
    [[ -n "$hn" ]] || continue
    HARNESS_BIN["$hn"]="$hb"
  done <<< "$hp"
  return 0
}

# role_repo <name> — repo path for a role (string form or object "repo"),
# with an optional worktree overlay resolved by relay.sh. rc 1 when unknown.
role_repo() {
  local line="${ROLE_CFG_LINE[$1]:-}" p
  if [[ "$line" == \{* ]]; then
    p="$(printf '%s' "$line" | sed -n 's/.*"repo": *"\([^"]*\)".*/\1/p')"
  else
    p="${line//\"/}"; p="${p//,/}"
    p="$(printf '%s' "$p" | xargs)"
  fi
  [[ -n "$p" ]] && { printf '%s\n' "$p"; return 0; }
  return 1
}

# role_field <role> <key> — a per-role string field from the object form
# (harness / model / args / worktree …); empty when unset.
role_field() {
  [[ -n "${ROLE_CFG_LINE[$1]:-}" ]] || return 0
  printf '%s' "${ROLE_CFG_LINE[$1]}" | sed -n "s/.*\"$2\": *\"\([^\"]*\)\".*/\1/p"
}

# harness_bin <harness> — the CLI to run: config override → built-in default.
harness_bin() {
  case "$1" in
    zcode)  printf '%s\n' "${HARNESS_BIN[$1]:-__ZCODE__}" ;;
    claude) printf '%s\n' "${HARNESS_BIN[$1]:-claude}" ;;
    codex)  printf '%s\n' "${HARNESS_BIN[$1]:-codex}" ;;
    *)      [[ -n "${HARNESS_BIN[$1]:-}" ]] && printf '%s\n' "${HARNESS_BIN[$1]}" || return 1 ;;
  esac
}

# coord_paths — legacy entry point every script already calls; config-aware.
coord_paths() { COORD="$COORD_DIR_LIB"; load_roles; }

# --- relay hooks ---------------------------------------------------------------

# run_hooks <event> — best-effort execute hooks/<event>.d/*.sh with the
# ORCH_* environment describing the dispatch (see hooks/README.md).
# Never fails the relay: hook errors and timeouts are swallowed.
run_hooks() {
  local ev="$1" d h to=""
  d="$COORD_DIR_LIB/hooks/$ev.d"
  [[ -d "$d" ]] || return 0
  command -v timeout >/dev/null 2>&1 && to="timeout 20"
  for h in "$d"/*.sh; do
    [[ -e "$h" ]] || continue
    ( export ORCH_EVENT="$ev"; $to bash "$h" ) >/dev/null 2>&1 || true
  done
  return 0
}

# --- node resolution ------------------------------------------------------------

# find_node — resolve a node executable even when PATH (e.g. a bash spawned
# from CMD) doesn't include it. Prints the path; returns 1 if none found.
# Override the whole search with the ZCODE_NODE env var.
find_node() {
  local c
  if [[ -n "${ZCODE_NODE:-}" && -x "${ZCODE_NODE:-}" ]]; then
    echo "$ZCODE_NODE"; return 0
  fi
  if command -v node >/dev/null 2>&1; then
    command -v node; return 0
  fi
  for c in \
    "C:/Program Files/nodejs/node.exe" \
    "C:/Program Files (x86)/nodejs/node.exe" \
    "/c/Program Files/nodejs/node.exe" \
    "/mnt/c/Program Files/nodejs/node.exe" \
    "${LOCALAPPDATA:-$HOME/AppData/Local}/Programs/node/node.exe" \
    "$HOME/AppData/Roaming/nvm"/*/node.exe; do
    [[ -x "$c" ]] && { echo "$c"; return 0; }
  done
  return 1
}

# --- sessions registry (no node needed) ------------------------------------------

# sess_get <sessions.json> <role> — extract a role's session id (or empty);
# relay.sh writes the file in a stable 2-space-indent format.
sess_get() {
  sed -n 's/^ *"'"$2"'": "\(sess_[^"]*\)".*/\1/p' "$1" 2>/dev/null | head -n 1
}

# --- zcode CLI resolution --------------------------------------------------------

# find_cli — resolve the headless zcode CLI: explicit override first, then the
# common Windows install path, then PATH. Prints the path; rc 1 if none.
find_cli() {
  local c
  for c in "${ZCODE_CLI:-}" \
    "C:/Users/$USERNAME/AppData/Local/Programs/ZCode/resources/glm/zcode.cjs" \
    "$HOME/AppData/Local/Programs/ZCode/resources/glm/zcode.cjs" \
    "$(command -v zcode 2>/dev/null || true)"; do
    [[ -n "$c" && -f "$c" ]] && { echo "$c"; return 0; }
  done
  return 1
}

# --- guards ------------------------------------------------------------------------

# relay/inspect drive the Windows ZCode CLI, whose session store is the
# Windows user profile (~/.zcode under C:\Users\…). WSL bash has a different
# home and different path semantics — running them there would split the
# session registry. They must run under Git Bash on Windows.
require_gitbash() {
  local k; k="$(env_kind)"
  [[ "$k" == "gitbash" ]] || \
    die "must run under Git Bash on Windows (detected: $k) — WSL/Linux cannot share the Windows ZCode session store"
}

# --- git snapshot cache ----------------------------------------------------------

# repo_snapshot <repo-path> [ttl_seconds] — prints 3 lines (branch, dirty
# count, last commit), cached under $TMPDIR for ttl (default 60s).
# NEVER blocks: a cold or stale cache serves a placeholder (or the stale
# data) immediately and refreshes in the background — git status on /mnt/f
# (WSL drvfs) can take tens of seconds and must not freeze a frame.
repo_snapshot() {
  local p="$1" ttl="${2:-60}" key cf age
  key="$(printf '%s' "$p" | tr '/\\: ' '____')"
  local cachedir="${TMPDIR:-/tmp}/bnch-repo"
  mkdir -p "$cachedir" 2>/dev/null
  cf="$cachedir/$key"
  if [[ -s "$cf" ]]; then
    age=$(( $(date +%s) - $(stat -c %Y "$cf" 2>/dev/null || date -r "$cf" +%s 2>/dev/null || echo 0) ))
    if (( age >= ttl )); then
      ( _repo_snapshot_fill "$p" "$cf" ) >/dev/null 2>&1 &
    fi
    cat "$cf"; return 0
  fi
  ( _repo_snapshot_fill "$p" "$cf" ) >/dev/null 2>&1 &
  printf '…collecting git info\n-\n-\n'
}

_repo_snapshot_fill() {
  local p="$1" cf="$2" lock="$2.lock" tf age
  # one fill per repo at a time — a slow fill must not race a newer one
  if [[ -f "$lock" ]]; then
    age=$(( $(date +%s) - $(stat -c %Y "$lock" 2>/dev/null || date -r "$lock" +%s 2>/dev/null || echo 0) ))
    (( age < 45 )) && return 0
  fi
  : > "$lock" 2>/dev/null || return 0
  tf="$cf.tmp.$RANDOM"
  local tg="timeout 30"; command -v timeout >/dev/null 2>&1 || tg=""
  {
    $tg git -C "$p" branch --show-current 2>/dev/null || echo '-'
    $tg git -C "$p" status --short 2>/dev/null | wc -l | tr -d ' '
    $tg git -C "$p" log -1 --pretty=format:'%h %s' 2>/dev/null || echo '-'
  } > "$tf" 2>/dev/null
  mv -f "$tf" "$cf" 2>/dev/null
  rm -f "$lock" 2>/dev/null
}

die() { echo "error: $*" >&2; exit 1; }
