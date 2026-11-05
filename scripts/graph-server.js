#!/usr/bin/env node
// graph-server.js — zero-dependency HTTP server serving the orchestration
// graph GUI: agents as nodes, orchestrator on top, edges animate while a
// relay is talking to an agent; node state = working/idle/waiting/silent.
// Tasks (ledger/tasks.json) render as chips under the node that holds them
// and as circles that travel along the edges while a relay is in flight;
// clicking a chip/token/feature opens the task panel with its full move
// history — every hop orchestrator↔agent with the reason for the move.
// State is read live from ../ledger on every /api/state request; the page
// polls every 2s. Usage: node graph-server.js [port]   (default 8787)
'use strict';
const http = require('http');
const fs = require('fs');
const path = require('path');

const LEDGER = path.resolve(__dirname, '..', 'ledger');
const MESSAGES = path.join(LEDGER, 'messages');
// ---------- orchestration config ----------
const CONFIG_PATH = process.env.ORCH_CONFIG ||
  path.resolve(__dirname, '..', 'orchestration.json');
let ROLES = ['backend', 'admin-front', 'customer-front'];
let PROJECT = 'AGENT-ORCHESTRA';
try {
  const cfg = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8'));
  if (cfg.roles && Object.keys(cfg.roles).length) {
    ROLES = Object.keys(cfg.roles);
  }
  if (cfg.project) PROJECT = String(cfg.project).toUpperCase();
} catch (e) { /* no config — generic defaults */ }
// spread role nodes across the 960-wide viewBox, centered under the orchestrator
const POS = {};
ROLES.forEach((r, i) => {
  const n = ROLES.length;
  const spread = n > 1 ? Math.min(320, 760 / (n - 1)) : 0;
  POS[r] = [Math.round(480 + (i - (n - 1) / 2) * spread), 330];
});

// ---------- state from the ledger ----------
function stampToDate(st) {
  if (!/^(\d{8})-(\d{6})$/.test(st || '')) return null;
  return new Date(+st.slice(0, 4), +st.slice(4, 6) - 1, +st.slice(6, 8),
                  +st.slice(9, 11), +st.slice(11, 13), +st.slice(13, 15));
}
function agoMin(d) { return d ? Math.max(0, Math.round((Date.now() - d.getTime()) / 60000)) : null; }
function hhmm(st) { const d = stampToDate(st); return d ? String(d.getHours()).padStart(2, '0') + ':' + String(d.getMinutes()).padStart(2, '0') : null; }

function readRoles() {
  let sessions = {};
  try { sessions = JSON.parse(fs.readFileSync(path.join(LEDGER, 'sessions.json'), 'utf8')); } catch (e) {}
  const out = {};
  let files = [];
  try { files = fs.readdirSync(MESSAGES); } catch (e) {}
  for (const role of ROLES) {
    const stamps = files
      .filter(f => f.startsWith(role + '-') && f.endsWith('-out.md'))
      .map(f => (f.match(/(\d{8}-\d{6})/) || [])[1])
      .filter(Boolean).sort();
    let pairs = 0, lastReply = null, inflight = null;
    for (const st of stamps) {
      if (fs.existsSync(path.join(MESSAGES, role + '-' + st + '-reply.md'))) { pairs++; lastReply = st; }
      else inflight = st;
    }
    let hb = '', hbAgo = null;
    try {
      const f = path.join(LEDGER, 'heartbeats', role + '.md');
      const lines = fs.readFileSync(f, 'utf8').trim().split('\n');
      hb = lines[lines.length - 1] || '';
      hbAgo = agoMin(new Date(fs.statSync(f).mtime));
    } catch (e) {}
    let state = 'none', ifo = null;
    if (sessions[role]) {
      state = 'idle';
      if (inflight) {
        state = 'working';
        let outAgo = null;
        try { outAgo = agoMin(new Date(fs.statSync(path.join(MESSAGES, role + '-' + inflight + '-stderr.log')).mtime)); } catch (e) {}
        if (outAgo !== null && outAgo >= 15) state = 'silent';
        ifo = { stamp: inflight, startedAgo: agoMin(stampToDate(inflight)), lastOutAgo: outAgo };
      }
    }
    out[role] = {
      sess: sessions[role] || null,
      state, heartbeat: hb, heartbeatAgo: hbAgo,
      msgs: pairs, inflight: ifo,
      lastDispatch: hhmm(stamps[stamps.length - 1] || null),
      lastReply: hhmm(lastReply),
    };
  }
  return out;
}

function readFeatures() {
  const feats = [];
  let files = [];
  try { files = fs.readdirSync(LEDGER).filter(f => /^FEAT-.*\.md$/.test(f)); } catch (e) {}
  for (const f of files) {
    try {
      const t = fs.readFileSync(path.join(LEDGER, f), 'utf8').split('\n');
      const title = (t[0] || '').replace(/^# /, '');
      const status = (t.find(l => l.startsWith('- Status:')) || '').replace('- Status:', '').trim();
      const updated = (t.find(l => l.startsWith('- Updated:')) || '').replace('- Updated:', '').trim();
      feats.push({ title, status, updated });
    } catch (e) {}
  }
  return feats;
}

function readTasks() {
  try { return JSON.parse(fs.readFileSync(path.join(LEDGER, 'tasks.json'), 'utf8')); } catch (e) { return {}; }
}

function readState() {
  const roles = readRoles();
  const features = readFeatures();
  const tasks = readTasks();
  let activity = [];
  try { activity = fs.readFileSync(path.join(LEDGER, 'activity.log'), 'utf8').trim().split('\n').slice(-12); } catch (e) {}
  const inflight = Object.values(roles).filter(r => r.inflight).length;
  const now = new Date();
  return {
    now: String(now.getHours()).padStart(2, '0') + ':' + String(now.getMinutes()).padStart(2, '0') + ':' + String(now.getSeconds()).padStart(2, '0'),
    roles, features, tasks, activity,
    orchestrator: { inflight, features: features.length },
  };
}

// ---------- the page (no backticks inside; served as-is) ----------
const PAGE = '<!doctype html><html><head><meta charset="utf-8">'
+ '<title>Agent Orchestration</title><style>'
+ 'body{margin:0;background:#0b1220;color:#e2e8f0;font-family:"Segoe UI",system-ui,sans-serif;display:flex;flex-direction:column;height:100vh}'
+ 'header{display:flex;justify-content:space-between;align-items:center;padding:10px 18px;background:#111c33;border-bottom:1px solid #24314f}'
+ 'header h1{font-size:16px;margin:0;letter-spacing:.12em}#clock{color:#7dd3fc;font-size:13px}'
+ 'main{flex:1;display:flex;min-height:0;position:relative}'
+ '#graphwrap{flex:1;display:flex;align-items:center;justify-content:center;padding:8px}'
+ 'svg{width:100%;max-width:980px;height:auto;max-height:100%}'
+ 'aside{width:330px;border-left:1px solid #24314f;padding:12px 14px;overflow-y:auto;font-size:12px}'
+ 'aside h2{font-size:11px;letter-spacing:.15em;color:#64748b;margin:10px 0 6px;text-transform:uppercase}'
+ '#features li{list-style:none;margin:4px 0;padding:6px 8px;background:#111c33;border-radius:6px;display:flex;justify-content:space-between;gap:8px;cursor:pointer}'
+ '#features li:hover{background:#1c2a4a}#features span{white-space:nowrap}#activity li{list-style:none;margin:3px 0;color:#94a3b8;font-family:Consolas,monospace;font-size:11px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}'
+ '.st-done{color:#34d399}.st-blocked,.st-negotiating{color:#f87171}.st-front-applying,.st-backend-in-flight,.st-backend-queued,.st-analyzing,.st-requested,.st-contract-published,.st-active{color:#fbbf24}'
+ '.a-START{color:#7dd3fc}.a-END{color:#34d399}.a-FAILED{color:#f87171}'
+ 'footer{padding:6px 18px;background:#111c33;border-top:1px solid #24314f;color:#64748b;font-size:11px}'
+ '.edge{stroke:#334155;stroke-width:2}.edge.active{stroke:#fbbf24;stroke-width:2.5;stroke-dasharray:8 6;animation:dash 1s linear infinite}'
+ '.edge.dead{stroke:#f87171;stroke-dasharray:8 6;animation:dash 1s linear infinite}'
+ '@keyframes dash{to{stroke-dashoffset:-14}}'
+ '.node rect{fill:#111c33;stroke-width:2}'
+ '.n-working rect{stroke:#fbbf24;animation:pulse 1.6s ease-in-out infinite}'
+ '.n-idle rect{stroke:#34d399}.n-none rect{stroke:#475569;stroke-dasharray:5 4}.n-silent rect{stroke:#f87171;animation:pulse 1s ease-in-out infinite}'
+ '@keyframes pulse{0%,100%{opacity:1}50%{opacity:.55}}'
+ '.name{fill:#e2e8f0;font-size:14px;font-weight:600}.chip{font-size:10px;letter-spacing:.1em}'
+ '.c-working{fill:#fbbf24}.c-idle{fill:#34d399}.c-none{fill:#64748b}.c-silent{fill:#f87171}'
+ '.hb{fill:#94a3b8;font-size:10px}.meta{fill:#64748b;font-size:10px}'
+ '.elabel{fill:#64748b;font-size:10px;font-family:Consolas,monospace}'
+ '.tchip{cursor:pointer}.tchip rect{fill:#1e293b;stroke:#475569;rx:9}'
+ '.tchip:hover rect{stroke:#7dd3fc;fill:#233257}.tchip text{fill:#93c5fd;font-size:10px;font-family:Consolas,monospace;pointer-events:none}'
+ '.tokcircle{fill:#fbbf24;stroke:#0b1220;stroke-width:2;cursor:pointer;filter:drop-shadow(0 0 6px #fbbf24aa)}'
+ '.toklabel{fill:#fde68a;font-size:10px;font-family:Consolas,monospace;paint-order:stroke;stroke:#0b1220;stroke-width:3px;pointer-events:none}'
+ '#panel{position:absolute;top:0;right:330px;bottom:0;width:340px;background:#0e1729f2;border-left:1px solid #24314f;padding:14px 16px;overflow-y:auto;display:none;z-index:5;font-size:12px}'
+ '#panel h3{margin:0 0 2px;font-size:14px}#panel .sub{color:#64748b;margin-bottom:10px}'
+ '#panel .mv{margin:8px 0;padding:8px;border-left:3px solid #334155;background:#111c33;border-radius:0 6px 6px 0}'
+ '#panel .mv .who{font-family:Consolas,monospace;color:#7dd3fc}#panel .mv .t{color:#64748b;font-size:10px}'
+ '#panel .mv .why{margin-top:3px;color:#cbd5e1}#panel .x{position:absolute;top:8px;right:12px;cursor:pointer;color:#94a3b8;background:none;border:none;font-size:16px}'
+ '#panel .kpi{display:flex;gap:14px;margin:8px 0;color:#94a3b8}#panel .kpi b{display:block;color:#e2e8f0;font-size:15px}'
+ '</style></head><body>'
+ '<header><h1>' + PROJECT + ' ORCHESTRATION</h1><div id="clock">connecting…</div></header>'
+ '<main><div id="graphwrap"><svg id="svg" viewBox="0 0 960 520"><g id="maing"></g><g id="tokg"></g></svg></div>'
+ '<div id="panel"><button class="x" onclick="hidePanel()">×</button><div id="panelbody"></div></div>'
+ '<aside><h2>Features (click for task history)</h2><ul id="features" style="padding:0;margin:0"></ul>'
+ '<h2>Activity</h2><ul id="activity" style="padding:0;margin:0"></ul></aside></main>'
+ '<footer>click a task in the features list, a chip under a node, or a moving token → panel with duration + every move and its reason · amber circle = task in transit on the connector (looping while the relay runs, returns on reply) · chips under a node = tasks it holds</footer>'
+ '<script>'
+ 'function $(id){return document.getElementById(id)}'
+ 'function esc(s){return String(s==null?"":s).replace(/[<>&"]/g,function(c){return {"<":"&lt;",">":"&gt;","&":"&amp;","\\"":"&quot;"}[c]})}'
+ 'function wrap(s,n){s=String(s||"");var a=s.slice(0,n),b=s.slice(n,2*n);if(b.length===n)b=b.slice(0,n-1)+"…";else if(!b&&a.length===n)a=a.slice(0,n-1)+"…";return [a,b].filter(Boolean)}'
+ 'function shortId(id){return String(id).replace(/^FEAT-\\d{8}-/,"").slice(0,22)}'
+ 'function parseT(s){if(!s)return null;var m=String(s).match(/(\\d{4})-(\\d{2})-(\\d{2})[ T](\\d{2}):(\\d{2})/);return m?new Date(+m[1],+m[2]-1,+m[3],+m[4],+m[5]):null}'
+ 'function fmtDur(ms){if(ms<0)ms=0;var m=Math.round(ms/60000);if(m<60)return m+"m";var h=Math.floor(m/60);if(h<24)return h+"h"+(m%60)+"m";return Math.floor(h/24)+"d "+(h%24)+"h"}'
+ 'var POS=' + JSON.stringify(POS) + ';var ORCH=[480,110];var TASKS={};var PREV={};var TOKENS=[];'
+ 'function heldBy(holder,doneToo){var out=[];for(var id in TASKS){var t=TASKS[id];if(t.holder===holder&&(doneToo||t.status!=="done"))out.push(id)}return out}'
+ 'function card(x,y,name,d,held){var cls="n-"+d.state;'
+ 'var h=["WORKING — relay in flight","IDLE — waiting for work","WAITING — no session yet","SILENT "+(d.inflight&&d.inflight.lastOutAgo!=null?d.inflight.lastOutAgo+"m":"")][{working:0,idle:1,none:2,silent:3}[d.state]];'
+ 'var hb=wrap(d.heartbeat,34);var H=130+held.length*20;'
+ 'var s="<g class=\\"node "+cls+"\\">";'
+ 's+="<rect x=\\""+(x-110)+"\\" y=\\""+(y-52)+"\\" width=\\"220\\" height=\\""+H+"\\" rx=\\"12\\"/>";'
+ 's+="<text class=\\"name\\" x=\\""+x+"\\" y=\\""+(y-28)+"\\" text-anchor=\\"middle\\">"+esc(name)+"</text>";'
+ 's+="<text class=\\"chip c-"+d.state+"\\" x=\\""+x+"\\" y=\\""+(y-10)+"\\" text-anchor=\\"middle\\">"+esc(h)+"</text>";'
+ 'if(hb[0])s+="<text class=\\"hb\\" x=\\""+x+"\\" y=\\""+(y+10)+"\\" text-anchor=\\"middle\\">"+esc(hb[0])+"</text>";'
+ 'if(hb[1])s+="<text class=\\"hb\\" x=\\""+x+"\\" y=\\""+(y+24)+"\\" text-anchor=\\"middle\\">"+esc(hb[1])+"</text>";'
+ 'var m="msgs "+d.msgs+(d.lastDispatch?" · out "+d.lastDispatch:"")+(d.lastReply?" · reply "+d.lastReply:"");'
+ 's+="<text class=\\"meta\\" x=\\""+x+"\\" y=\\""+(y+46)+"\\" text-anchor=\\"middle\\">"+esc(m)+"</text>";'
+ 'if(d.inflight)s+="<text class=\\"meta\\" x=\\""+x+"\\" y=\\""+(y+62)+"\\" text-anchor=\\"middle\\">started "+d.inflight.startedAgo+"m ago · last output "+(d.inflight.lastOutAgo==null?"?":d.inflight.lastOutAgo+"m")+" ago</text>";'
+ 'for(var i=0;i<held.length&&i<4;i++){var cy=y+78+i*20;'
+ 's+="<g class=\\"tchip\\" data-task=\\""+esc(held[i])+"\\"><rect x=\\""+(x-100)+"\\" y=\\""+cy+"\\" width=\\"200\\" height=\\"17\\" rx=\\"8\\"/><text x=\\""+x+"\\" y=\\""+(cy+12)+"\\" text-anchor=\\"middle\\">"+esc(shortId(held[i]))+"</text></g>"}'
+ 'if(held.length>4)s+="<text class=\\"meta\\" x=\\""+x+"\\" y=\\""+(y+78+4*20)+"\\" text-anchor=\\"middle\\">+"+(held.length-4)+" more</text>";'
+ 'return s+"</g>"}'
+ 'function orchBox(st){var held=heldBy("orchestrator",false);var H=64+held.length*20;'
+ 'var s="<g class=\\"node n-orch\\"><rect x=\\""+(ORCH[0]-130)+"\\" y=\\""+(ORCH[1]-34)+"\\" width=\\"260\\" height=\\""+H+"\\" rx=\\"12\\" style=\\"stroke:#7dd3fc;fill:#111c33;stroke-width:2\\"/>"'
+ '+ "<text class=\\"name\\" x=\\""+ORCH[0]+"\\" y=\\""+(ORCH[1]-8)+"\\" text-anchor=\\"middle\\">ORCHESTRATOR</text>"'
+ '+ "<text class=\\"meta\\" x=\\""+ORCH[0]+"\\" y=\\""+(ORCH[1]+14)+"\\" text-anchor=\\"middle\\">"+st.orchestrator.inflight+" relay(s) talking · "+held.length+" task(s) in hand</text>";'
+ 'for(var i=0;i<held.length&&i<4;i++){var cy=ORCH[1]+26+i*20;'
+ 's+="<g class=\\"tchip\\" data-task=\\""+esc(held[i])+"\\"><rect x=\\""+(ORCH[0]-120)+"\\" y=\\""+cy+"\\" width=\\"240\\" height=\\"17\\" rx=\\"8\\"/><text x=\\""+ORCH[0]+"\\" y=\\""+(cy+12)+"\\" text-anchor=\\"middle\\">"+esc(shortId(held[i]))+"</text></g>"}'
+ 'return s+"</g>"}'
+ 'function edge(ox,oy,tx,ty,d){var cls="edge"+(d.state==="working"?" active":d.state==="silent"?" dead":"");'
+ 'var mx=(ox+tx)/2,my=(oy+ty)/2;var lbl=" msgs "+d.msgs+" ";'
+ 'return "<line class=\\""+cls+"\\" x1=\\""+ox+"\\" y1=\\""+oy+"\\" x2=\\""+tx+"\\" y2=\\""+ty+"\\"/>"'
+ '+ "<rect x=\\""+(mx-38)+"\\" y=\\""+(my-9)+"\\" width=\\"76\\" height=\\"16\\" rx=\\"4\\" fill=\\"#0b1220\\"/>"'
+ '+ "<text class=\\"elabel\\" x=\\""+mx+"\\" y=\\""+(my+3)+"\\" text-anchor=\\"middle\\">"+esc(lbl)+"</text>"}'
+ 'function render(st){TASKS=st.tasks||{};$("clock").textContent=st.now+" · "+st.orchestrator.inflight+" in flight · "+st.orchestrator.features+" features";'
+ 'var s="<defs></defs>";'
+ 's+=orchBox(st);'
+ 'for(var role in POS){var d=st.roles[role];var p=POS[role];var held=heldBy(role,true);'
+ 's+=edge(ORCH[0],ORCH[1]+34,p[0],p[1]-56,d);s+=card(p[0],p[1],role,d,held)}'
+ '$("maing").innerHTML=s;'
+ '$("features").innerHTML=st.features.map(function(f){return "<li data-task=\\""+esc(f.title)+"\\"><b>"+esc(f.title)+"</b><span class=\\"st-"+esc(f.status)+"\\">"+esc(f.status)+"</span></li>"}).join("");'
+ '$("activity").innerHTML=st.activity.map(function(l){var c=l.indexOf("START")>=0?"a-START":l.indexOf("END")>=0?"a-END":l.indexOf("FAILED")>=0?"a-FAILED":"";return "<li class=\\""+c+"\\">"+esc(l)+"</li>"}).join("");'
+ 'updateTokens(st)}'
// ---- task tokens: circles that travel along the connectors ----
+ 'function spawnTok(role,dir,loop,taskId){TOKENS.push({role:role,dir:dir,loop:loop,t0:performance.now(),dur:loop?2600:2800,task:taskId||null})}'
+ 'function updateTokens(st){for(var role in st.roles){var now=st.roles[role].inflight?st.roles[role].inflight.stamp:null;var was=PREV[role];'
+ 'if(now&&!was){var held=heldBy(role,true);spawnTok(role,1,true,held[0]||null)}'
+ 'if(!now&&was){var back=null;TOKENS=TOKENS.filter(function(k){if(k.role===role&&k.loop){back=k.task;return false}return true});spawnTok(role,-1,false,back)}'
+ 'PREV[role]=now}}'
+ 'function lerp(a,b,p){return a+(b-a)*p}'
+ 'function drawTokens(){var g=$("tokg");if(!g)return;while(g.firstChild)g.removeChild(g.firstChild);'
+ 'var now=performance.now();var NS="http://www.w3.org/2000/svg";'
+ 'TOKENS=TOKENS.filter(function(k){var p=k.loop?((now-k.t0)/k.dur)%1:(now-k.t0)/k.dur;if(!k.loop&&p>=1)return false;var q=k.dir===1?p:1-p;'
+ 'var p2=POS[k.role];if(!p2)return false;var ax=ORCH[0],ay=ORCH[1]+34,bx=p2[0],by=p2[1]-56;'
+ 'var x=lerp(ax,bx,q),y=lerp(ay,by,q)+(k.loop?Math.sin(p*Math.PI*2)*0:0);'
+ 'var c=document.createElementNS(NS,"circle");c.setAttribute("cx",x);c.setAttribute("cy",y);c.setAttribute("r",7);c.setAttribute("class","tokcircle");'
+ 'if(k.task)c.setAttribute("data-task",k.task);g.appendChild(c);'
+ 'if(k.task){var t=document.createElementNS(NS,"text");t.setAttribute("x",x);t.setAttribute("y",y+18);t.setAttribute("class","toklabel");t.setAttribute("text-anchor","middle");t.textContent=shortId(k.task);g.appendChild(t)}'
+ 'return true});'
+ 'requestAnimationFrame(drawTokens)}'
+ 'requestAnimationFrame(drawTokens);'
// ---- task panel: duration + every move with its reason ----
+ 'function showTask(id){var t=TASKS[id];if(!t)return;var c=parseT(t.created);var dur=c?fmtDur(Date.now()-c.getTime()):"?";'
+ 'var h="<h3>"+esc(shortId(id))+"</h3><div class=\\"sub\\">"+esc(id)+" · status <b class=\\"st-"+esc(t.status)+"\\">"+esc(t.status)+"</b> · holder "+esc(t.holder||"-")+"</div>"'
+ '+ "<div class=\\"kpi\\"><div><b>"+esc(dur)+"</b>since created</div><div><b>"+(t.history?t.history.length:0)+"</b>moves</div></div>";'
+ 'if(t.history)h+=t.history.map(function(m){return "<div class=\\"mv\\"><div class=\\"t\\">"+esc(m.t)+"</div><div class=\\"who\\">"+esc(m.from)+" → "+esc(m.to)+"</div><div class=\\"why\\">"+esc(m.why)+"</div></div>"}).join("");'
+ '$("panelbody").innerHTML=h;$("panel").style.display="block"}'
+ 'function hidePanel(){$("panel").style.display="none"}'
+ '$("svg").addEventListener("click",function(ev){var el=ev.target.closest("[data-task]");if(el)showTask(el.getAttribute("data-task"))});'
+ '$("features").addEventListener("click",function(ev){var el=ev.target.closest("[data-task]");if(el)showTask(el.getAttribute("data-task"))});'
+ 'async function tick(){try{var r=await fetch("/api/state");render(await r.json())}catch(e){$("clock").textContent="offline — graph server stopped"}}'
+ 'setInterval(tick,2000);tick();'
+ '<\/script></body></html>';

// ---------- server ----------
function listen(portLeft) {
  const port = portLeft;
  const srv = http.createServer((req, res) => {
    if (req.url === '/' || req.url === '/index.html') {
      res.setHeader('content-type', 'text/html; charset=utf-8');
      res.end(PAGE);
    } else if (req.url === '/api/state') {
      res.setHeader('content-type', 'application/json; charset=utf-8');
      res.setHeader('access-control-allow-origin', '*');
      res.end(JSON.stringify(readState()));
    } else { res.statusCode = 404; res.end('not found'); }
  });
  srv.on('error', e => {
    if (e.code === 'EADDRINUSE' && port < 8787 + 10) { console.log('port ' + port + ' busy, trying ' + (port + 1)); listen(port + 1); }
    else { console.error('cannot listen: ' + e.message); process.exit(1); }
  });
  srv.listen(port, () => console.log('orchestration graph on http://localhost:' + port));
}
listen(parseInt(process.argv[2] || '8787', 10));
