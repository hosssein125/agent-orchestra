#!/usr/bin/env bash
# watchdog.sh — automate the R18 liveness duty AND the R23 decode-first rule.
#
# A relay is suspect when it has an un-replied transcript (in flight) AND its
# stderr log hasn't moved in a while. But before any dispatch is declared
# dead, its raw CLI envelope (<role>-<stamp>.json) is decoded: a complete
# envelope means only the WRAPPER died — the agent actually finished, and
# its reply is recovered at zero cost (this exact case recovered two
# "crashed" dispatches in the first live run).
#
# Usage:
#   scripts/watchdog.sh                  report every in-flight relay's state
#   scripts/watchdog.sh --auto-orphan    act on suspects past the threshold:
#                                        envelope complete → RECOVER the reply
#                                        (write transcript, record session,
#                                        END (recovered) in activity.log,
#                                        return the task to the orchestrator);
#                                        otherwise → write the R18 orphan
#                                        marker so the role can re-dispatch
#   WATCHDOG_ORPHAN_MIN=90               raise/lower the threshold (default 60)
#
# After recovery/orphaning, re-dispatch with the salvage notice:
#   scripts/relay.sh <role> --salvage …   (R17 is injected automatically)
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPTS_DIR/lib.sh"
coord_paths || die "cannot locate the coordination workspace"
LEDGER="$COORD_DIR_LIB/ledger"
MESSAGES="$LEDGER/messages"
THRESH="${WATCHDOG_ORPHAN_MIN:-60}"
auto=0
[[ "${1:-}" == "--auto-orphan" ]] && auto=1
node_bin="$(find_node || true)"

now=$(date +%s)
mfile_age() { local mt; mt="$(stat -c %Y "$1" 2>/dev/null || date -r "$1" +%s 2>/dev/null || echo 0)"; echo $(( (now - mt) / 60 )); }
stamp_age() { # minutes since a YYYYMMDD-HHMMSS stamp
  local st="$1" d t ep
  [[ "$st" =~ ^([0-9]{8})-([0-9]{6})$ ]] || { echo 0; return; }
  d="${BASH_REMATCH[1]}"; t="${BASH_REMATCH[2]}"
  ep="$(date -d "${d:0:4}-${d:4:2}-${d:6:2} ${t:0:2}:${t:2:2}:${t:4:2}" +%s 2>/dev/null || echo "$now")"
  echo $(( (now - ep) / 60 ))
}

# envelope_complete <json-file> — prints "sess<TAB>in<TAB>out" and rc 0 when
# the file holds a COMPLETE reply, for any harness shape (zcode / claude /
# codex JSONL) — the R23 "decode, don't trust the exit code" check, shared
# with relay.sh via scripts/envelope.js.
envelope_complete() {
  [[ -n "$node_bin" && -s "$1" ]] || return 1
  "$node_bin" "$SCRIPTS_DIR/envelope.js" "$1" 2>/dev/null
}

# recover_reply <role> <stamp> <out-file> — the wrapper died, the agent did
# not: materialize the reply from the envelope, record the session, log the
# END (recovered) line, and return any task the role held to the orchestrator.
recover_reply() {
  local role="$1" st="$2" out="$3" jsonf="${out%-out.md}.json" replyf="${out%-out.md}-reply.md"
  local meta sess tokin tokout resp
  meta="$("$node_bin" "$SCRIPTS_DIR/envelope.js" "$jsonf" --full 2>/dev/null)" || return 1
  _head="$(printf '%s' "$meta" | head -n1)"
  sess="$(printf '%s' "$_head" | cut -f1)"
  tokin="$(printf '%s' "$_head" | cut -f2)"
  tokout="$(printf '%s' "$_head" | cut -f3)"
  resp="$(printf '%s' "$meta" | cut -f4-)"
  {
    echo "# <- $role  ($st — RECOVERED from envelope by watchdog, R23)"
    echo
    echo "- session: $sess"
    echo
    echo "$resp"
  } > "$replyf"
  # record/refresh the session id (same contract as relay.sh)
  if [[ -n "$sess" && "$sess" != "?" ]]; then
    "$node_bin" -e '
      const fs=require("fs");
      const [f,role,sess]=process.argv.slice(1);
      const s=JSON.parse(fs.readFileSync(f,"utf8"));
      if(s[role]!==sess){s[role]=sess;fs.writeFileSync(f,JSON.stringify(s,null,2)+"\n");}
    ' "$LEDGER/sessions.json" "$role" "$sess" || true
  fi
  local el; el="$(stamp_age "$st")"
  echo "$(date '+%Y-%m-%d %H:%M:%S') | END    | $role | ${sess:-?} | ${el}m (recovered) | tokens in=$tokin out=$tokout" >> "$LEDGER/activity.log"
  # return any task the role held (same movement contract as relay.sh)
  "$node_bin" -e '
    const fs=require("fs");
    const [f,role]=process.argv.slice(1);
    let j={};try{j=JSON.parse(fs.readFileSync(f,"utf8"))}catch(e){process.exit(0)}
    const n=new Date(),p=x=>String(x).padStart(2,"0");
    const t=n.getFullYear()+"-"+p(n.getMonth()+1)+"-"+p(n.getDate())+" "+p(n.getHours())+":"+p(n.getMinutes());
    for(const id of Object.keys(j)){
      if(j[id].holder===role&&j[id].status!=="done"){
        j[id].history.push({t:t,from:role,to:"orchestrator",why:"reply recovered from envelope after wrapper crash (R23)"});
        j[id].holder="orchestrator";j[id].updated=t;
      }
    }
    fs.writeFileSync(f,JSON.stringify(j,null,2)+"\n");
  ' "$LEDGER/tasks.json" "$role" || true
  echo "  → RECOVERED complete reply: $(basename "$replyf") (session ${sess:-?}, ${el}m elapsed) — no re-dispatch needed, the agent had finished"
  return 0
}

found=0; suspects=0
for out in "$MESSAGES"/*-out.md; do
  [[ -e "$out" ]] || continue
  reply="${out%-out.md}-reply.md"
  [[ -f "$reply" ]] && continue
  found=1
  st="$(basename "$out" | grep -oE '[0-9]{8}-[0-9]{6}')"
  role="$(basename "$out" | sed -n 's/^\([a-z0-9-]*\)-[0-9]\{8\}-[0-9]\{6\}-out\.md$/\1/p')"
  el="$(stamp_age "$st")"
  errf="${out%-out.md}-stderr.log"
  silence=999
  [[ -f "$errf" ]] && silence="$(mfile_age "$errf")"

  # R23 first: a complete envelope means the wrapper died, not the agent
  envmeta=""
  envmeta="$(envelope_complete "${out%-out.md}.json")" || true
  if [[ -n "$envmeta" ]]; then
    echo "RECOVERABLE  $role  started $st (${el} min ago) — envelope holds a COMPLETE reply (wrapper-only crash, R23)"
    if [[ $auto -eq 1 ]]; then
      recover_reply "$role" "$st" "$out" || echo "  → recovery failed — treat as orphan candidate"
    else
      echo "  → re-run with --auto-orphan to recover the reply at zero cost"
    fi
    suspects=$((suspects+1))
    continue
  fi

  if (( silence >= THRESH )); then
    echo "DEAD-SUSPECT  $role  started $st (${el} min ago) — no output for ${silence} min (threshold ${THRESH}); envelope has no complete reply"
    if [[ $auto -eq 1 ]]; then
      cat > "$reply" <<EOF
# <- $role  ($st — ORPHANED by watchdog)

The relay dispatching this message died without replying: no CLI output for
${silence} minutes (watchdog threshold ${THRESH} min, $(date '+%Y-%m-%d %H:%M:%S')),
and the raw envelope holds no complete reply (decoded first, R23).
The out-transcript is $(basename "$out").

Re-dispatch with the salvage notice — \`scripts/relay.sh $role --salvage …\`
(R17): "a previous attempt died mid-work; committed or uncommitted partial
work may exist on the branch — audit and salvage before redoing."
EOF
      echo "  → orphan marker written: $(basename "$reply") (in-flight cleared; re-dispatch with --salvage)"
    else
      echo "  → verify the process; if dead: re-run with --auto-orphan, then re-dispatch with --salvage"
    fi
    suspects=$((suspects+1))
  elif (( silence >= 15 )); then
    echo "VERIFY        $role  started $st (${el} min ago) — silent ${silence} min (R18: confirm the process is alive)"
    suspects=$((suspects+1))
  else
    echo "ALIVE         $role  started $st (${el} min ago) — last output ${silence} min ago"
  fi
done

(( found == 0 )) && echo "✓ no relays in flight"
(( suspects > 0 )) && exit 2
exit 0
