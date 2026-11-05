#!/usr/bin/env bash
# init.sh — adopt this orchestration for YOUR set of repos.
#
# The coordination scripts are generic; what makes a workspace yours is
# orchestration.json (roles → repo paths), the generated AGENTS.md runbook,
# per-role briefings, and the ledger. This script scaffolds all of it.
#
# Usage:
#   scripts/init.sh --target ../MyCoordination [options]   new workspace
#   scripts/init.sh --here                                 (re)write THIS
#                                                          repo's orchestration.json
#
# Options (any left out is asked interactively):
#   --name <project>          project name shown in dashboards/docs
#   --roles <n=path,...>      role names and their repo paths (absolute)
#   --axes "a,b,c"            overlap-check axes (default: endpoints,schemas,permissions,migrations)
#   --contract-root <dir>     where backend contract notes live (default Docs/frontend)
#   --force                   scaffold into a non-empty target
#
# Example (fully non-interactive):
#   scripts/init.sh --target ../ShopCoord --name Shop \
#     --roles api=F:/Projects/shop-api,web=F:/Projects/shop-web \
#     --axes "endpoints,schemas,permissions" --contract-root Docs/frontend
#
# The target gets: scripts/, rules/RULES.md (seeded with everything this
# orchestration learned in live runs — that's the point), templates/,
# hooks/ (see hooks/README.md), ledger/ (empty), prompts/role-*.md,
# AGENTS.md, README.md, orchestration.json. Then run:
#   scripts/relay.sh --check      in the target to validate.
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_ROOT="$(cd "$SCRIPTS_DIR/.." && pwd)"
source "$SCRIPTS_DIR/lib.sh"

target=""; here=0; force=0
name=""; roles_arg=""; axes=""; croot=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)       target="$2"; shift 2 ;;
    --here)         here=1; shift ;;
    --name)         name="$2"; shift 2 ;;
    --roles)        roles_arg="$2"; shift 2 ;;
    --axes)         axes="$2"; shift 2 ;;
    --contract-root) croot="$2"; shift 2 ;;
    --default-harness) dh="$2"; shift 2 ;;
    --force)        force=1; shift ;;
    -h|--help)      sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "error: unknown arg '$1'" >&2; exit 1 ;;
  esac
done

ask() { local v=""; read -r -p "$1 " v; echo "$v"; }

# ---- gather inputs ------------------------------------------------------------
[[ -n "$roles_arg" ]] || {
  echo "No --roles given — entering interactive setup."
  echo "Give each role agent a name and its repo path (the repo it lives in)."
  echo "One per line as  name=path ; empty line to finish."
  echo "  e.g.  backend=F:/Projects/my-api"
  while :; do
    line="$(ask 'role (name=repo-path, blank to finish):')"
    [[ -z "$line" ]] && break
    [[ "$line" == *=* ]] || { echo "  (skipped — expected name=path)"; continue; }
    roles_arg="${roles_arg:+$roles_arg,}$line"
  done
}
[[ -n "$roles_arg" ]] || { echo "error: no roles defined — nothing to scaffold" >&2; exit 1; }

[[ -n "$name"   ]] || name="$(ask "project name [$(basename "${target:-$SRC_ROOT}" | sed 's/Coordination$//;s/Coord$//')]:")"
[[ -n "$axes"   ]] || axes="endpoints,schemas/DTOs,permissions,migrations"
[[ -n "$croot"  ]] || croot="Docs/frontend"
dh="${dh:-zcode}"   # default harness: zcode | claude | codex | custom

# normalize role specs name=path[@harness] → RP (name=path) + RH (harness|"")
declare -a RP=() RH=()
IFS=',' read -ra _pairs <<< "$roles_arg"
for p in "${_pairs[@]}"; do
  r="${p%%=*}"; v="${p#*=}"; h=""
  if [[ "$v" == *@* ]]; then h="${v##*@}"; v="${v%@*}"; fi
  RP+=( "$r=$v" ); RH+=( "$h" )
done

# write_config <dest> — orchestration.json from RP/RH (object form when a
# role pins a harness or the default isn't zcode)
write_config() {
  local dest="$1" r v h first=1
  {
    echo '{'
    echo "  \"project\": \"$name\","
    [[ "$dh" != "zcode" ]] && echo "  \"harness_default\": \"$dh\","
    echo '  "roles": {'
    for i in "${!RP[@]}"; do
      r="${RP[$i]%%=*}"; v="${RP[$i]#*=}"; h="${RH[$i]}"
      (( first )) || echo ','
      first=0
      if [[ -n "$h" || "$dh" != "zcode" ]]; then
        printf '    "%s": {"repo": "%s"%s}' "$r" "$v" "${h:+, \"harness\": \"$h\"}"
      else
        printf '    "%s": "%s"' "$r" "$v"
      fi
    done
    echo ''
    echo '  },'
    ax="$(printf '%s' "$axes" | sed 's/ *, */", "/g')"
    echo "  \"overlap_axes\": [\"$ax\"],"
    echo "  \"contract_note_root\": \"$croot\""
    echo '}'
  } > "$dest"
}

# ---- --here: just (re)write this repo's config ---------------------------------
if [[ $here -eq 1 ]]; then
  cfg="$SRC_ROOT/orchestration.json"
  [[ -f "$cfg" ]] && { cp "$cfg" "$cfg.bak"; echo "backed up existing config → $cfg.bak"; }
  write_config "$cfg"
  echo "wrote $cfg — validating:"
  bash "$SCRIPTS_DIR/relay.sh" --check
  exit $?
fi

# ---- scaffold a new workspace --------------------------------------------------
[[ -n "$target" ]] || { echo "error: --target <dir> required (or --here)" >&2; exit 1; }
target="$(cd "$(dirname "$target")" 2>/dev/null && pwd)/$(basename "$target")" || target="$(pwd)/$target"
if [[ -d "$target" && -n "$(ls -A "$target" 2>/dev/null)" && $force -eq 0 ]]; then
  echo "error: target exists and is not empty: $target (use --force)" >&2; exit 1
fi
mkdir -p "$target"/{scripts,rules,templates,prompts,docs} \
         "$target"/ledger/{messages,heartbeats} \
         "$target"/hooks/{on-start.d,on-reply.d,on-fail.d}

echo "scaffolding $target …"
cp "$SCRIPTS_DIR"/*.sh "$SCRIPTS_DIR"/graph-server.js "$SCRIPTS_DIR"/envelope.js "$target/scripts/"
cp "$SRC_ROOT/rules/RULES.md" "$target/rules/RULES.md"
cp "$SRC_ROOT"/templates/*.md "$SRC_ROOT"/templates/*.json "$target/templates/" 2>/dev/null || true
cp "$SRC_ROOT"/hooks/README.md "$target/hooks/README.md" 2>/dev/null || true
for d in on-start on-reply on-fail; do
  cp "$SRC_ROOT/hooks/$d.d"/*.example "$target/hooks/$d.d/" 2>/dev/null || true
done
cp "$SRC_ROOT/.gitignore" "$target/.gitignore" 2>/dev/null || printf '*.tmp\n*.log\n!ledger/activity.log\nhooks/notify.url\n' > "$target/.gitignore"
: > "$target/ledger/activity.log"
printf '{}\n' > "$target/ledger/tasks.json"

write_config "$target/orchestration.json"

# sessions.json: every role null (fresh session on first relay)
{
  echo '{'
  first=1
  for i in "${!RP[@]}"; do
    r="${RP[$i]%%=*}"
    (( first )) || echo ','
    first=0
    printf '  "%s": null' "$r"
  done
  echo ''
  echo '}'
} > "$target/ledger/sessions.json"

# render templates → AGENTS.md, README.md, ledger/TEMPLATE.md, prompts/role-*.md
render() { # $1=src-template  $2=dest  followed by VAR=VAL pairs
  local src="$1" dst="$2"; shift 2
  local t; t="$(cat "$src")"
  local kv
  for kv in "$@"; do t="${t//\{\{${kv%%=*}\}\}/${kv#*=}}"; done
  printf '%s\n' "$t" > "$dst"
}

rolenames="$(printf '%s' "$roles_arg" | sed 's/=@[^,]*//g; s/=[^,]*//g; s/,/\|/g')"
axes_bullets=""; IFS=',' read -ra _ax <<< "$axes"
for a in "${_ax[@]}"; do axes_bullets+="- ${a}: <clean | overlap>
"; done

roles_table=""
for i in "${!RP[@]}"; do
  r="${RP[$i]%%=*}"; v="${RP[$i]#*=}"; h="${RH[$i]}"
  roles_table+="| \`$r\` | \`$v\`${h:+ (harness: $h)} |
"
  render "$SRC_ROOT/templates/role-briefing.md" "$target/prompts/role-$r.md" \
    PROJECT="$name" ROLE="$r" REPO="$v" \
    HEARTBEAT_FILE="$target/ledger/heartbeats/$r.md" \
    CONTRACT_ROOT="$croot"
done

render "$SRC_ROOT/templates/AGENTS.md" "$target/AGENTS.md" \
  PROJECT="$name" ROLES_TABLE="$roles_table" ROLENAMES="$rolenames" \
  AXES="$axes" AXES_BULLETS="$axes_bullets" CONTRACT_ROOT="$croot"
render "$SRC_ROOT/templates/ledger-TEMPLATE.md" "$target/ledger/TEMPLATE.md" \
  AXES_BULLETS="$axes_bullets" CONTRACT_ROOT="$croot"
render "$SRC_ROOT/templates/README-workspace.md" "$target/README.md" \
  PROJECT="$name" ROLENAMES="$rolenames"

echo "done. validate the new workspace:"
echo "  bash $target/scripts/relay.sh --check"
bash "$target/scripts/relay.sh" --check || echo "  (fix the issues above — usually repo paths or harness bins)"
echo
echo "next steps:"
echo "  1. review $target/AGENTS.md and $target/prompts/role-*.md (they are yours to edit)"
echo "  2. open an agent session in $target — AGENTS.md is the orchestrator runbook"
echo "  3. first dispatch per its rules (readiness ping first, R21)"
echo "  4. optional: hooks/on-reply.d/*.example → rename to .sh (webhook/telegram/PR — hooks/README.md)"
