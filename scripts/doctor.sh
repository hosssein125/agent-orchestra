#!/usr/bin/env bash
# doctor.sh — one-command health check of the whole orchestration, deeper than
# relay.sh --check (which only validates setup): registry consistency, ledger
# hygiene, suspicious dispatches, hooks, and recent failures.
#
# Usage:  scripts/doctor.sh
# Exit 0 = healthy, 1 = problems found. ⚠ lines are warnings (not fatal).
set -uo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPTS_DIR/lib.sh"
coord_paths || die "cannot locate the coordination workspace"
LEDGER="$COORD_DIR_LIB/ledger"
ZCODE_CLI="${ZCODE_CLI:-C:/Users/Hossein/AppData/Local/Programs/ZCode/resources/glm/zcode.cjs}"

errors=0; warnings=0
ok()   { printf '  ✓ %s\n' "$1"; }
bad()  { printf '  ✗ %s\n' "$1"; errors=$((errors+1)); }
warn() { printf '  ⚠ %s\n' "$1"; warnings=$((warnings+1)); }

echo "== environment =="
node_bin="$(find_node || true)"
[[ -n "$node_bin" ]] && ok "node ($node_bin)" || bad "node not found — set ZCODE_NODE"
[[ -f "$ZCODE_CLI" ]] && ok "zcode CLI ($ZCODE_CLI)" || bad "zcode CLI missing at $ZCODE_CLI (override ZCODE_CLI)"
case "$(env_kind)" in
  gitbash) ok "shell: Git Bash (relay/inspect usable)" ;;
  *)       warn "shell: $(env_kind) — relay.sh/inspect.sh need Git Bash on Windows" ;;
esac

echo "== config (orchestration.json) =="
cfg="$(orch_config)"
if [[ -f "$cfg" ]]; then
  ok "config found ($cfg)"
  PROJECT_NAME="${PROJECT_NAME:-}"  # coord_paths already loaded it
  [[ -n "$PROJECT_NAME" ]] && ok "project: $PROJECT_NAME" || warn "project name missing in config"
  for r in $ROLES; do
    p="$(role_repo "$r")"
    [[ -d "$p" ]] && ok "role $r → $p" || bad "role $r repo missing: $p"
    h="$(role_field "$r" harness)"; [[ -n "$h" ]] || h="$HARNESS_DEFAULT"
    case "$h" in
      zcode) [[ -n "$(find_cli 2>/dev/null || true)" ]] && ok "role $r harness zcode (CLI found)" || bad "role $r harness zcode: CLI not found (set ZCODE_CLI)" ;;
      claude|codex)
        b="$(harness_bin "$h" 2>/dev/null || true)"
        if command -v "$b" >/dev/null 2>&1 || [[ -x "$b" ]]; then ok "role $r harness $h ($b)"
        else warn "role $r harness $h: '$b' not on PATH — install it or set harnesses.$h.bin"; fi ;;
      *) b="$(harness_bin "$h" 2>/dev/null || true)"
         [[ -n "$b" ]] && { command -v "$b" >/dev/null 2>&1 && ok "role $r harness $h ($b)" || warn "role $r harness $h bin not executable: $b"; } \
                       || warn "role $r harness $h has no bin (add harnesses.$h.bin)" ;;
    esac
    wt="$(role_field "$r" worktree)"
    if [[ -n "$wt" ]]; then
      [[ "$wt" == "auto" ]] && wt="$(dirname "$(role_repo "$r")")/.orch-worktrees/$r"
      [[ -e "$wt/.git" ]] && ok "role $r worktree: $wt" || warn "role $r worktree missing: $wt (created on next relay)"
    fi
  done
else
  warn "no orchestration.json — run scripts/init.sh --here to define roles (or scaffold with --target)"
fi

echo "== session registry =="
SF="$LEDGER/sessions.json"
if [[ -f "$SF" ]]; then
  if [[ -n "$node_bin" ]]; then
    "$node_bin" -e "JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'))" "$SF" 2>/dev/null \
      && ok "sessions.json is valid JSON" || bad "sessions.json is INVALID JSON — fix before the next relay"
  fi
  for r in $ROLES; do
    if grep -q "\"$r\"" "$SF" 2>/dev/null; then
      s="$(sess_get "$SF" "$r")"
      [[ -n "$s" ]] && ok "$r has a session" || warn "$r is null (fresh session on next relay)"
    else
      warn "$r missing from sessions.json (first relay will add it)"
    fi
  done
else
  bad "sessions.json missing"
fi

echo "== ledger hygiene =="
ACT="$LEDGER/activity.log"
[[ -f "$ACT" ]] && ok "activity.log exists ($(wc -l < "$ACT" | tr -d ' ') lines)" || warn "activity.log missing (created by first relay)"
unreplied=0; silent=0
for out in "$LEDGER/messages"/*-out.md; do
  [[ -e "$out" ]] || continue
  if [[ ! -f "${out%-out.md}-reply.md" ]]; then
    unreplied=$((unreplied+1))
    errf="${out%-out.md}-stderr.log"
    if [[ -f "$errf" ]]; then
      mt="$(stat -c %Y "$errf" 2>/dev/null || date -r "$errf" +%s 2>/dev/null || echo 0)"
      age=$(( ($(date +%s) - mt) / 60 ))
      (( age >= 15 )) && { warn "$(basename "$out") in flight, silent ${age} min — run scripts/watchdog.sh"; silent=$((silent+1)); }
    fi
  fi
done
(( unreplied == 0 )) && ok "no un-replied dispatches" || warn "$unreplied dispatch(s) in flight (see watch.sh status)"
(( silent == 0 )) || true
fails=0
if [[ -f "$ACT" ]]; then
  fails="$(grep -c '| FAILED |' "$ACT")" || true
  [[ "$fails" =~ ^[0-9]+$ ]] || fails=0
fi
if (( fails > 0 )); then
  warn "$fails FAILED dispatch(es) in activity.log — last: $(grep '| FAILED |' "$ACT" | tail -n 1 | cut -c1-100)"
else
  ok "no failed dispatches recorded"
fi
feats=( "$LEDGER"/FEAT-*.md ); [[ -e "${feats[0]}" ]] && ok "${#feats[@]} feature file(s)" || warn "no feature files yet"
[[ -d "$LEDGER/heartbeats" ]] && ok "heartbeats dir exists" || warn "heartbeats dir missing (role briefings expect it)"
if [[ -f "$LEDGER/tasks.json" && -n "$node_bin" ]]; then
  "$node_bin" -e "JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'))" "$LEDGER/tasks.json" 2>/dev/null \
    && ok "tasks.json is valid JSON" || bad "tasks.json is INVALID JSON — fix before the next relay (the graph reads it)"
else
  warn "tasks.json missing (created by task.sh new / first --task relay)"
fi

echo "== hooks =="
for d in "$COORD_DIR_LIB/hooks"/*.d; do
  [[ -d "$d" ]] || continue
  for h in "$d"/*.sh; do
    [[ -e "$h" ]] || continue
    bash -n "$h" 2>/dev/null && ok "$(basename "$d")/$(basename "$h")" || bad "$(basename "$h") fails bash -n"
  done
done
[[ -d "$COORD_DIR_LIB/hooks" ]] || ok "(no hooks dir — none configured)"

echo
if (( errors > 0 )); then echo "PROBLEMS: $errors error(s), $warnings warning(s)"; exit 1; fi
if (( warnings > 0 )); then echo "OK WITH WARNINGS: $warnings warning(s)"; exit 0; fi
echo "ALL HEALTHY"
