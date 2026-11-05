# Adoption guide — use this orchestration on your repos

You have N repos (or N areas) that one product team ships against, a
headless coding-agent CLI (ZCode; `ZCODE_CLI` overrides the path), bash
(Git Bash on Windows), and node. Twenty minutes later you have an
orchestrator agent coordinating one persistent role agent per repo, with
conflict detection, transcripts, heartbeats, dashboards, and a learning
rulebook. Nothing to install globally; everything is plain files.

## 1. Scaffold the workspace

```bash
git clone <this-repo> orchestration-src
bash orchestration-src/scripts/init.sh --target ../MyCoord --name MyProj \
  --roles api=/abs/path/my-api,web=/abs/path/my-web,ml=/abs/path/my-ml \
  --axes "endpoints,schemas,permissions,migrations" \
  --contract-root Docs/frontend
```

- `--roles` — `name=repo-path` pairs. Names become everything: role ids,
  transcript prefixes (`ledger/messages/<role>-<stamp>-*.md`), heartbeat
  files, config keys. Use dashes, not spaces.
- `--axes` — the overlap dimensions your conflict checks compare across.
  For an API + frontends, endpoints/schemas/permissions/migrations is the
  proven set; for a monorepo split by service, name your shared surfaces.
- `--contract-root` — where the contract-owning role writes artifact notes
  others consume (default `Docs/frontend`).
- Interactive mode: omit `--roles` (and any other flag) and answer prompts.
- `--here` instead of `--target` rewrites THIS repo's `orchestration.json`
  (backs up the old one).

The target gets: `scripts/`, `templates/`, `hooks/`, `ledger/` (empty),
`prompts/role-*.md` rendered per role, a generated `AGENTS.md` runbook,
`README.md`, `rules/RULES.md` — **pre-seeded with the 28 rules this
orchestration earned in live runs** (the seed is the point), and
`orchestration.json`. Re-run `init.sh --force` anytime to refresh the
scaffold without losing the ledger.

## 2. Validate

```bash
cd ../MyCoord
bash scripts/relay.sh --check     # CLI, node, repos, registry
bash scripts/doctor.sh            # deep health: config, ledger, hooks, history
```

Typical fixes: `ZCODE_CLI` env var if the CLI lives elsewhere; repo paths
must be absolute.

## 3. Start the orchestrator

Open a ZCode session **in the coordination directory**. `AGENTS.md` is
auto-loaded and is the orchestrator's complete runbook: intake → overlap
check → dispatch → contract gate → dependents → close, plus the failure
protocol. Your first message can be a feature description in plain words.

Before the first real dispatch, the runbook has the orchestrator spend a
readiness ping ("Reply ACK only, change nothing") to surface CLI/session
problems cheaply (R21).

## 4. Make it yours (the five files worth reading)

| File | You'll change it to… |
|------|----------------------|
| `prompts/role-*.md` | Teach each role its repo's law: conventions, branch policy, what counts as a contract-surface change, its heartbeat file. The reply protocol at the bottom is what the orchestrator parses — keep it. |
| `AGENTS.md` | Rename lifecycle states, tune escalation policy, adjust the overlap workflow to your reality. |
| `rules/RULES.md` | Read once; then it grows itself — every feature close-out appends lessons (R13). |
| `orchestration.json` | Roles/axes later; `scripts/doctor.sh` validates. |
| `hooks/` | Enable notifications: `cp hooks/on-reply.d/notify-webhook.sh.example hooks/on-reply.d/notify-webhook.sh` then put a Discord/Slack/generic webhook URL in `hooks/notify.url` (gitignored). |

## 5. Daily driving

```bash
bash scripts/dashboard.sh        # terminal dashboard (menu-driven)
bash scripts/graph.sh            # browser topology GUI
bash scripts/watch.sh live       # follow heartbeats + dispatch log
bash scripts/inspect.sh <role>   # open the role's real session in the TUI
bash scripts/stats.sh            # cost per role/day
bash scripts/search.sh "login"   # every transcript mentioning it
```

In practice you mostly do nothing: describe features to the orchestrator,
get pinged by the webhook when dispatches land, and answer the rare
product question it escalates.

## Role naming suggestions

- One **contract-owning** role (the backend / API / shared-lib repo) —
  single-writer by rule (R1).
- N **consumer** roles (frontends, clients) — they may run in parallel
  (R3) and file proposals when they need new backend surface.
- Optional: a `reviewer`/`qa` role later — roles are config entries; add
  one to `orchestration.json` + a `prompts/role-<name>.md`, done.

## Multi-harness: mix ZCode, Claude Code, Codex, anything

Every role can run on its own harness — the pattern the 2026 orchestrators
converged on (Claude coordinating, Codex executing, per-role specialists).
In `orchestration.json`:

```json
{
  "harness_default": "zcode",
  "roles": {
    "backend": "C:/Projects/my-api",
    "web":     { "repo": "C:/Projects/my-web", "harness": "claude", "model": "sonnet" },
    "review":  { "repo": "C:/Projects/my-api", "harness": "codex", "worktree": "auto",
                 "args": "--sandbox workspace-write" }
  },
  "harnesses": {
    "claude": { "bin": "claude" },
    "codex":  { "bin": "codex" },
    "mine":   { "bin": "C:/tools/my-agent-cli" }
  }
}
```

- `"harness_default"` — used by string-form roles (`zcode` if unset).
- Per-role object form: `repo` (required), `harness`, `model`, `args`
  (extra CLI flags, space-separated), `worktree`.
- `"harnesses"` — optional bin overrides; `claude`/`codex` default to PATH.

Built-in adapters: **zcode** (`-p … --cwd --mode --json --resume --attach`),
**claude** (`claude -p … --output-format json --resume`), **codex**
(`codex exec --json --cd …` / `exec resume`). Any other bin works as a
**custom** harness (prompt as last argument; pick up the reply from the
transcript/envelope). Permission modes map per harness:

| relay `-m` | zcode | claude | codex |
|---|---|---|---|
| `yolo` | `--mode yolo` | `--dangerously-skip-permissions` | `--full-auto` |
| `build` | `--mode build` | `--permission-mode acceptEdits` | `--sandbox workspace-write` |
| `plan`/`edit` | `--mode plan/edit` | `--permission-mode plan` / default | `--sandbox read-only` |

Attachments: zcode carries files natively (`--attach`); other harnesses get
them inlined into the prompt as `--- FILE: … ---` blocks. Everything else is
identical across harnesses — transcripts, session resume, task movements,
watchdog recovery, stats — because `scripts/envelope.js` decodes every
envelope shape (zcode JSON / claude JSON / codex JSONL). Verify a setup with
`relay.sh <role> --dry-run` (prints the exact command) and `doctor.sh`.

**Worktree isolation** — `"worktree": "auto"` dispatches the role inside
`<repo>/../.orch-worktrees/<role>` (created once off the current HEAD on
branch `orch/<role>`, reused after). Two roles can then work the same repo
in parallel without touching each other's tree — the claude-squad /
agent-teams pattern as one flag. Explicit path also accepted.

**Auto-commit the ledger** — `"auto_commit": true` (or env
`ORCH_AUTO_COMMIT=1`): after every reply the coordination repo commits the
ledger/state with a one-line message, so the audit trail stays pushed
without ceremony.

**Task → PR flow** — enable `hooks/on-reply.d/open-pr.sh.example` (rename
to `.sh`): when a role replies `STATUS: done` with a `BRANCH:`, it opens a
PR via `gh` in that role's repo. `notify-telegram.sh.example` pings a
Telegram chat on reply/failure.

## Multi-machine

Session ids (`ledger/sessions.json`) are machine-local: on a new machine,
set roles to `null`; sessions recreate on first relay. Commit the whole
coordination repo (it's the audit trail); transcripts include real code
paths, so keep the remote private unless you've reviewed them.

## Troubleshooting quick table

| Symptom | Do |
|---------|----|
| `relay.sh: role already has an in-flight dispatch` | `scripts/watchdog.sh` — it decodes the envelope first: a complete reply is RECOVERED with `--auto-orphan` (no re-dispatch needed); a dead one gets the orphan marker, then re-dispatch with `relay.sh <role> --salvage …` (the R17 audit-and-salvage notice is injected automatically) |
| Dispatch RUNNING forever, no stderr movement | Same — watchdog flags it; verify the process before orphaning |
| Contract gate says path missing | `scripts/contract-check.sh <repo> <stated-path>` — it resolves abbreviated paths (R24) |
| Wrong CLI path after an app update | `ZCODE_CLI=… bash scripts/relay.sh --check` |
| Session acting polluted/drifted | Set that role to `null` in `ledger/sessions.json`; next relay opens a fresh session |
| Everything on fire | `bash scripts/doctor.sh`, read the ledger — the answer is always a file in there |
