#!/usr/bin/env bash
# graph.sh — launch the orchestration graph GUI.
#
# Agents as nodes, orchestrator on top; edges animate while a relay is
# talking to that agent; node state shows working / idle / waiting / silent.
# Starts a tiny zero-dependency node HTTP server and opens the browser.
#
# Usage: scripts/graph.sh [--no-open] [--bg] [port]
#   --no-open   don't open the browser (e.g. when launched from dashboard.sh)
#   --bg        run DETACHED so the GUI survives this shell/terminal closing
#               (kills any previous instance first = restart semantics)
#   port        default 8787 (or GRAPH_PORT env)
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPTS_DIR/lib.sh"

node_bin="$(find_node)" || die "node not found — set ZCODE_NODE"
PORT="${GRAPH_PORT:-8787}"
OPEN=1; BG=0
for a in "$@"; do
  case "$a" in
    --no-open) OPEN=0 ;;
    --bg)      BG=1; OPEN=0 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) [[ "$a" =~ ^[0-9]+$ ]] && PORT="$a" ;;
  esac
done

# --- --bg: detached mode -------------------------------------------------------
# A plain `&` subshell dies with its parent terminal (Git Bash kills the
# process group) — that is why the GUI went missing after the dashboard
# closed. Detach properly: kill the previous instance (restart semantics),
# then spawn detached (PowerShell Start-Process on Windows, nohup elsewhere)
# and only report success once the server actually answers.
port_pid() { # PID listening on $PORT, empty if none (Windows netstat)
  netstat -ano 2>/dev/null | awk -v p=":$PORT" 'tolower($0) ~ /listening/ && $2 ~ p"$" {print $NF; exit}'
}
if [[ "$BG" == 1 ]]; then
  pid="$(port_pid)"
  if [[ -n "$pid" ]]; then
    taskkill //F //PID "$pid" >/dev/null 2>&1 || pkill -f graph-server.js 2>/dev/null || true
    sleep 0.4
  fi
  case "$(env_kind)" in
    gitbash)
      wn="$(cygpath -w "$node_bin")"; ws="$(cygpath -w "$SCRIPTS_DIR/graph-server.js")"
      powershell -NoProfile -Command "Start-Process -FilePath '$wn' -ArgumentList '$ws','$PORT' -WindowStyle Hidden" >/dev/null 2>&1 \
        || ( nohup "$node_bin" "$SCRIPTS_DIR/graph-server.js" "$PORT" >/dev/null 2>&1 & )
      ;;
    *)
      ( nohup "$node_bin" "$SCRIPTS_DIR/graph-server.js" "$PORT" >/dev/null 2>&1 & )
      ;;
  esac
  ok=0
  for _ in $(seq 1 24); do
    if curl -s -m 1 -o /dev/null "http://127.0.0.1:$PORT/"; then ok=1; break; fi
    sleep 0.25
  done
  if [[ $ok -eq 1 ]]; then
    echo "graph GUI ready → http://localhost:$PORT (detached; survives this terminal)"
  else
    echo "error: graph GUI did not come up on port $PORT — try running: scripts/graph.sh" >&2
    exit 1
  fi
  exit 0
fi

echo "orchestration graph → http://localhost:$PORT  (Ctrl-C to stop)"
if [[ "$OPEN" == 1 ]]; then
  (
    sleep 1
    url="http://localhost:$PORT"
    cmd //c start "" "$url" 2>/dev/null || cmd.exe /c start "" "$url" 2>/dev/null \
      || echo "open $url in your browser"
  ) &
fi
exec "$node_bin" "$SCRIPTS_DIR/graph-server.js" "$PORT"
