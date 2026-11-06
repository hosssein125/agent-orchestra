#!/usr/bin/env bash
# _test-harness.sh — multi-harness e2e: fake zcode/claude/codex CLIs, worktree
# isolation, auto-commit. Builds a throwaway workspace, never touches Bonnychow.
set -uo pipefail
SRC="F:/Projects/BonnychowCoordination"
T="/tmp/HarnessTest"
rm -rf "$T"; mkdir -p "$T/bin"

# --- fake CLIs -----------------------------------------------------------------
cat > "$T/bin/fake-claude" <<'EOF'
#!/usr/bin/env bash
# minimal claude CLI: last -p arg is the prompt; print a claude-shaped envelope
printf '{"session_id":"sess_fake_claude_1","result":"claude-style reply line.\\nSTATUS: done\\nBRANCH: -\\nGATES: pass","usage":{"input_tokens":555,"output_tokens":33,"cache_read_input_tokens":1200}}\n'
EOF
cat > "$T/bin/fake-codex" <<'EOF'
#!/usr/bin/env bash
# minimal codex CLI: prints JSONL events
printf '{"type":"session_configured","session_id":"sess_fake_codex_7"}\n'
printf '{"type":"agent_message","message":"codex-style reply line."}\n'
printf '{"type":"turn.completed","total_token_usage":{"input":900,"output":44}}\n'
EOF
chmod +x "$T/bin/fake-claude" "$T/bin/fake-codex"

# fake zcode CLI (node): zcode-shaped envelope
cat > "$T/bin/fake-zcode.cjs" <<'EOF'
console.log(JSON.stringify({sessionId:"sess_fake_zcode_9",usage:{inputTokens:321,outputTokens:12},response:"zcode-style reply line.\nSTATUS: done\nGATES: pass"}));
EOF

# --- a tiny git repo to coordinate + a worktree-capable product repo ----------
git init -q "$T/prod" && ( cd "$T/prod" && git config user.email t@t && git config user.name t \
  && echo hello > f.txt && git add -A && git commit -qm init )

# --- scaffold the workspace with init.sh (mixed harnesses) ---------------------
bash "$SRC/scripts/init.sh" --target "$T/ws" --name HT \
  --roles api="$T/prod",rev="$T/prod@claude",cx="$T/prod@codex",wt="$T/prod" \
  >/dev/null 2>&1
# wt role gets worktree:auto via a config rewrite (init keeps it simple)
node -e '
const fs=require("fs");const f=process.argv[1];
const j=JSON.parse(fs.readFileSync(f,"utf8"));
j.harnesses={claude:{bin:process.argv[2]},codex:{bin:process.argv[3]}};
j.roles.wt={"repo":process.argv[4],"harness":"claude","worktree":"auto"};
j.auto_commit=false;
fs.writeFileSync(f,JSON.stringify(j,null,2)+"\n");' "$T/ws/orchestration.json" \
  "$T/bin/fake-claude" "$T/bin/fake-codex" "$T/prod"

cd "$T/ws"

echo "== envelope.js unit checks =="
node "$SRC/scripts/envelope.js" <(printf '{"sessionId":"s1","usage":{"inputTokens":5,"outputTokens":2},"response":"hi"}') && echo " <- zcode shape OK"
printf '{"session_id":"s2","result":"hi2","usage":{"input_tokens":7,"output_tokens":3}}\n' > "$T/env-claude.json"
node "$SRC/scripts/envelope.js" "$T/env-claude.json" && echo " <- claude shape OK"
printf '{"type":"session_configured","session_id":"s3"}\n{"type":"agent_message","message":"hi3"}\n{"type":"turn.completed","total_token_usage":{"input":9,"output":4}}\n' > "$T/env-codex.jsonl"
node "$SRC/scripts/envelope.js" "$T/env-codex.jsonl" && echo " <- codex shape OK"
printf '{"session_id":"s4","resp' > "$T/env-partial.json"
node "$SRC/scripts/envelope.js" "$T/env-partial.json" 2>/dev/null && echo "PARTIAL WRONGLY ACCEPTED" || echo " <- incomplete rejected OK"

echo "== dispatch per harness =="
ZCODE_CLI="$T/bin/fake-zcode.cjs" bash scripts/relay.sh api --task FEAT-1 --why "t: zcode dispatch" "hello zcode" | head -1
bash scripts/relay.sh rev --task FEAT-1 --why "t: claude dispatch" "hello claude" | head -1
bash scripts/relay.sh cx  --task FEAT-1 --why "t: codex dispatch" "hello codex" | head -1

echo "== artifacts =="
echo "sessions: $(cat ledger/sessions.json | tr -d ' \n')"
echo "task moves:"; bash scripts/task.sh show FEAT-1 | sed -n '2,20p'
echo "activity ENDs:"; grep '| END' ledger/activity.log

echo "== worktree isolation =="
ZCODE_CLI="$T/bin/fake-zcode.cjs" bash scripts/relay.sh wt --task FEAT-2 "worktree dispatch" >/dev/null && \
  { [[ -d "$T/prod/../.orch-worktrees/wt" ]] && echo "worktree created: $(ls -d "$(dirname "$T/prod")/.orch-worktrees/wt")" || echo "WORKTREE MISSING"; }
ZCODE_CLI="$T/bin/fake-zcode.cjs" bash scripts/relay.sh wt --task FEAT-2 "worktree re-dispatch" >/dev/null && echo "second dispatch reused worktree OK"

echo "== auto-commit =="
git init -q . && git config user.email t@t && git config user.name t && git add -A && git commit -qm init
node -e 'const fs=require("fs");const f="orchestration.json";const j=JSON.parse(fs.readFileSync(f));j.auto_commit=true;fs.writeFileSync(f,JSON.stringify(j,null,2))'
ZCODE_CLI="$T/bin/fake-zcode.cjs" bash scripts/relay.sh api --task FEAT-3 "autocommit test" >/dev/null
git log --oneline | head -2
git show --stat HEAD | grep -c ledger && echo "ledger committed by auto-commit OK"
