#!/usr/bin/env node
// envelope.js — tolerant decoder for headless CLI envelopes, shared by
// relay.sh / watchdog.sh / doctor.sh. One script, every harness:
//   zcode   single JSON:  {sessionId, usage:{inputTokens,outputTokens}, response}
//   claude  single JSON:  {session_id, result, usage:{input_tokens,output_tokens,…}}
//   codex   JSONL events: session_id in any event, last agent_message as the
//                         reply, token counts from total_token_usage/usage
// Usage:
//   node envelope.js <file>            → "sess\tin\tout" on stdout, rc 0,
//                                        when the file holds a COMPLETE reply
//   node envelope.js <file> --full     → additionally the full response text
//                                        (used by relay to write the transcript)
// rc 1 = no complete reply yet (still running, or genuinely died).
'use strict';
const fs = require('fs');

const file = process.argv[2];
const full = process.argv[3] === '--full';
if (!file) { console.error('usage: envelope.js <file> [--full]'); process.exit(2); }

let raw;
try { raw = fs.readFileSync(file, 'utf8'); } catch (e) { process.exit(1); }
raw = raw.trim();
if (!raw) process.exit(1);

const pick = (o, ...keys) => {
  for (const k of keys) {
    const v = k.split('.').reduce((a, p) => (a == null ? a : a[p]), o);
    if (v !== undefined && v !== null) return v;
  }
  return undefined;
};
const num = v => (typeof v === 'number' ? v : (parseInt(v, 10) || 0));

function fromSingleJSON(j) {
  const sess = pick(j, 'sessionId', 'session_id', 'thread_id');
  const resp = pick(j, 'response', 'result', 'message');
  if (typeof resp !== 'string' || !resp.trim()) return null;
  return {
    sess: typeof sess === 'string' ? sess : '',
    in: num(pick(j, 'usage.inputTokens', 'usage.input_tokens', 'usage.cache_read_input_tokens')),
    out: num(pick(j, 'usage.outputTokens', 'usage.output_tokens')),
    resp,
  };
}
function fromJSONL(lines) {
  let sess = '', resp = '', tin = 0, tout = 0;
  for (const l of lines) {
    const s = l.trim();
    if (!s.startsWith('{') && !s.startsWith('[')) continue;
    let j; try { j = JSON.parse(s); } catch (e) { continue; }
    const sid = pick(j, 'session_id', 'sessionId', 'thread_id');
    if (!sess && typeof sid === 'string') sess = sid;
    const m = pick(j, 'message', 'agent_message', 'data.message');
    if (typeof m === 'string' && m.trim()) resp = m;          // last one wins
    const u = pick(j, 'total_token_usage', 'usage', 'token_count', 'info.token_usage');
    if (u && typeof u === 'object') {
      const i = pick(u, 'input', 'input_tokens', 'cached_input_tokens');
      const o = pick(u, 'output', 'output_tokens');
      if (i !== undefined) tin = num(i);
      if (o !== undefined) tout = num(o);
    }
  }
  if (!resp.trim()) return null;
  return { sess, in: tin, out: tout, resp };
}

let hit = null;
const start = raw.indexOf('{');
if (start >= 0 && !raw.includes('\n{')) {
  // single-envelope shape (zcode / claude)
  try { hit = fromSingleJSON(JSON.parse(raw.slice(start))); } catch (e) { hit = null; }
}
if (!hit) hit = fromJSONL(raw.split('\n'));
if (!hit) process.exit(1);

const out = [hit.sess || '?', String(hit.in), String(hit.out)];
if (full) out.push(hit.resp);
process.stdout.write(out.join('\t'));
process.exit(0);
