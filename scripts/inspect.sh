#!/usr/bin/env bash
# inspect.sh — open a role agent's session in the interactive ZCode TUI.
#
# This is the agent's real GUI: its full conversation transcript — every
# message, tool call, file edit, and command output — scrollable, and you
# can even type to the agent directly.
#
# Usage:
#   scripts/inspect.sh <backend|admin-front|customer-front> [--print] [--force]
#
#     --print   dry run: show the command instead of launching the TUI
#     --force   attach even while a relay is driving this role (unsafe —
#               two writers on one session)
#
# Safety:
#  - Attaching while a headless relay (-p --resume) is running the same
#    session is blocked by default: two processes writing one session can
#    corrupt the conversation state. Wait for the relay (watch.sh status
#    shows it as RUNNING) or use --force knowingly.
#  - Close the TUI before the orchestrator dispatches new work to this
#    role — your open TUI and the next relay would both write the session.
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COORD_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
source "$SCRIPTS_DIR/lib.sh"
coord_paths || die "no orchestration.json — run scripts/init.sh --here first"
ZCODE_CLI="${ZCODE_CLI:-$(find_cli || echo C:/Users/Hossein/AppData/Local/Programs/ZCode/resources/glm/zcode.cjs)}"
SESSIONS_FILE="$COORD_DIR/ledger/sessions.json"
MESSAGES_DIR="$COORD_DIR/ledger/messages"

role=""; do_print=0; force=0
for a in "$@"; do
  case "$a" in
    --print) do_print=1 ;;
    --force) force=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) [[ -z "$role" ]] && role="$a" || { echo "error: unexpected arg '$a'" >&2; exit 1; } ;;
  esac
done

[[ -n "$role" ]] || { echo "error: role required ($(echo "${ROLES:-role}" | tr ' ' '|'))" >&2; exit 1; }

require_gitbash   # the TUI must share the Windows ZCode session store

repo="$(role_repo "$role")" || { echo "error: unknown role '$role' (known: $(echo "$ROLES" | tr ' ' '|'))" >&2; exit 1; }

node_bin="$(find_node)" || die "node not found on PATH or common locations — set ZCODE_NODE"
[[ -f "$ZCODE_CLI" ]] || { echo "error: zcode CLI not found at $ZCODE_CLI (override with ZCODE_CLI)" >&2; exit 1; }
[[ -f "$SESSIONS_FILE" ]] || { echo "error: $SESSIONS_FILE not found" >&2; exit 1; }

# a running relay blocks inspection — even when the session id isn't
# recorded yet (first dispatch records it only on completion)
for out in "$MESSAGES_DIR/$role-"*-out.md; do
  [[ -e "$out" ]] || continue
  if [[ ! -f "${out%-out.md}-reply.md" ]]; then
    if [[ $force -eq 0 ]]; then
      echo "error: a relay is currently RUNNING for '$role' ($(basename "$out"))." >&2
      echo "       Attaching two writers to one session is unsafe, and on a first" >&2
      echo "       dispatch the session id is recorded only when the relay completes." >&2
      echo "       Wait for it (scripts/watch.sh status) or re-run with --force if you" >&2
      echo "       know better." >&2
      exit 1
    fi
    echo "warning: --force used while relay $(basename "$out") is running" >&2
  fi
done

sess="$(sess_get "$SESSIONS_FILE" "$role")"
[[ -n "$sess" ]] || { echo "error: no session yet for '$role' — dispatch work to it first (relay.sh)" >&2; exit 1; }

# harness-aware attach: each CLI has its own resume/TUI form
HARNESS="$(role_field "$role" harness)"
[[ -n "$HARNESS" ]] || HARNESS="$HARNESS_DEFAULT"
# worktree roles attach inside their worktree
cwd="$repo"
WT="$(role_field "$role" worktree)"
if [[ -n "$WT" ]]; then
  [[ "$WT" == "auto" ]] && WT="$(dirname "$repo")/.orch-worktrees/$role"
  [[ -d "$WT" ]] && cwd="$WT"
fi

launch() {
  case "$HARNESS" in
    zcode)  exec "$node_bin" "$ZCODE_CLI" --resume "$sess" --cwd "$cwd" ;;
    claude) cd "$cwd" && exec "$(harness_bin claude)" --resume "$sess" ;;
    codex)  cd "$cwd" && exec "$(harness_bin codex)" resume "$sess" ;;
    *)      echo "error: no known TUI form for harness '$HARNESS' — inspect manually with its own CLI" >&2; exit 1 ;;
  esac
}

if [[ $do_print -eq 1 ]]; then
  echo "DRY RUN — would launch (harness $HARNESS, cwd $cwd):"
  case "$HARNESS" in
    zcode)  echo "  $node_bin $ZCODE_CLI --resume $sess --cwd $cwd" ;;
    claude) echo "  (cd $cwd && $(harness_bin claude) --resume $sess)" ;;
    codex)  echo "  (cd $cwd && $(harness_bin codex) resume $sess)" ;;
    *)      echo "  (harness $HARNESS — manual)" ;;
  esac
  exit 0
fi

echo "Opening $role session $sess in the $HARNESS TUI (cwd $cwd)…"
echo "Remember: close it before the orchestrator dispatches new work to this role."
launch
