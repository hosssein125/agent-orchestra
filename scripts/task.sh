#!/usr/bin/env bash
# task.sh — manage the task movement log (ledger/tasks.json) that feeds the
# graph GUI's animated task tokens, per-agent task lists, and move history.
#
# relay.sh logs dispatch→agent and reply→orchestrator movements automatically
# (task inferred from a -f FEAT-*.md attach, or --task/--why). This helper
# covers the moves only the orchestrator knows about:
#
#   scripts/task.sh new FEAT-20261105-my-feature "intake: <what was asked>"
#   scripts/task.sh move FEAT-… admin-front "why this hand-off (negotiated R6)"
#   scripts/task.sh set  FEAT-… status=done
#   scripts/task.sh show FEAT-…
#   scripts/task.sh list
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPTS_DIR/lib.sh"
coord_paths || die "no orchestration.json — run scripts/init.sh --here first"
TASKS_FILE="$COORD_DIR_LIB/ledger/tasks.json"
node_bin="$(find_node || true)"
[[ -n "$node_bin" ]] || die "node not found — set ZCODE_NODE"

cmd="${1:-}"; id="${2:-}"
[[ "$cmd" == "list" || -n "$id" ]] || { sed -n '2,15p' "$0" >&2; exit 1; }

case "$cmd" in
  new)
    why="${3:-intake}"
    exec "$node_bin" -e '
      const fs=require("fs");const [f,id,why]=process.argv.slice(1);
      let j={};try{j=JSON.parse(fs.readFileSync(f,"utf8"))}catch(e){}
      const n=new Date(),p=x=>String(x).padStart(2,"0");
      const t=n.getFullYear()+"-"+p(n.getMonth()+1)+"-"+p(n.getDate())+" "+p(n.getHours())+":"+p(n.getMinutes());
      if(!j[id])j[id]={title:id,status:"active",created:t,holder:"orchestrator",history:[]};
      if(!j[id].history.length)j[id].history.push({t:t,from:"user",to:"orchestrator",why:why.slice(0,140)});
      j[id].updated=t;fs.writeFileSync(f,JSON.stringify(j,null,2)+"\n");
      console.log("task "+id+" created (holder: orchestrator)");
    ' "$TASKS_FILE" "$id" "$why"
    ;;
  move)
    to="${3:?to required}"; why="${4:?why required}"
    exec "$node_bin" -e '
      const fs=require("fs");const [f,id,to,why]=process.argv.slice(1);
      let j={};try{j=JSON.parse(fs.readFileSync(f,"utf8"))}catch(e){}
      if(!j[id]){console.error("unknown task "+id+" — create with: task.sh new");process.exit(1);}
      const n=new Date(),p=x=>String(x).padStart(2,"0");
      const t=n.getFullYear()+"-"+p(n.getMonth()+1)+"-"+p(n.getDate())+" "+p(n.getHours())+":"+p(n.getMinutes());
      const from=j[id].holder||"orchestrator";
      j[id].history.push({t:t,from:from,to:to,why:why.slice(0,140)});
      j[id].holder=to;j[id].updated=t;fs.writeFileSync(f,JSON.stringify(j,null,2)+"\n");
      console.log("moved "+id+": "+from+" -> "+to);
    ' "$TASKS_FILE" "$id" "$to" "$why"
    ;;
  set)
    kv="${3:?key=value required}"
    exec "$node_bin" -e '
      const fs=require("fs");const [f,id,kv]=process.argv.slice(1);
      let j={};try{j=JSON.parse(fs.readFileSync(f,"utf8"))}catch(e){}
      if(!j[id]){console.error("unknown task "+id);process.exit(1);}
      const i=kv.indexOf("=");if(i<1){console.error("expected key=value");process.exit(1);}
      j[id][kv.slice(0,i)]=kv.slice(i+1);
      fs.writeFileSync(f,JSON.stringify(j,null,2)+"\n");
      console.log(id+" "+kv);
    ' "$TASKS_FILE" "$id" "$kv"
    ;;
  show)
    exec "$node_bin" -e '
      const fs=require("fs");const [f,id]=process.argv.slice(1);
      let j={};try{j=JSON.parse(fs.readFileSync(f,"utf8"))}catch(e){}
      if(!j[id]){console.error("unknown task "+id);process.exit(1);}
      const t=j[id];console.log(t.title+"  status="+t.status+"  holder="+t.holder+"  created="+t.created);
      t.history.forEach(h=>console.log("  "+h.t+"  "+h.from+" -> "+h.to+"  — "+h.why));
    ' "$TASKS_FILE" "$id"
    ;;
  list)
    exec "$node_bin" -e '
      const fs=require("fs");const f=process.argv[1];
      let j={};try{j=JSON.parse(fs.readFileSync(f,"utf8"))}catch(e){}
      const ids=Object.keys(j);
      if(!ids.length){console.log("(no tasks)");}
      else ids.forEach(id=>console.log(id+"  status="+j[id].status+"  holder="+j[id].holder+"  moves="+j[id].history.length));
    ' "$TASKS_FILE"
    ;;
  *)
    sed -n '2,15p' "$0" >&2; exit 1 ;;
esac
