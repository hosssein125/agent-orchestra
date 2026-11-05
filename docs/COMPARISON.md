# Comparison with the top open-source agent orchestrations

Research date: 2026-11-05. We surveyed the highest-starred multi-agent /
orchestration projects relevant to *coding agents that edit real repos*,
extracted their feature sets, and decided for each: **adopt** (and where it
landed here), **have** (we already did it), or **skip** (and why). Star
counts are snapshots; the decisions are the point.

| Project | Stars | One-liner |
|---------|-------|-----------|
| [ruvnet/ruflo](https://github.com/ruvnet/ruflo) (ex claude-flow) | ~80k | Agent harness: swarms, shared memory, MCP tools, WebUI |
| [bmad-code-org/BMAD-METHOD](https://github.com/bmad-code-org/BMAD-METHOD) | ~55k | Agile AI-driven development: PM/Architect/Dev/QA agents, skills |
| [Yeachan-Heo/oh-my-claudecode](https://github.com/Yeachan-Heo/oh-my-claudecode) | ~41k | Teams-first multi-agent orchestration for Claude Code |
| [OrchestratorInc/agent-orchestrator](https://github.com/OrchestratorInc/agent-orchestrator) | ~14k | Plan/run/supervise fleets from task to merged PR (desktop+mobile) |
| [HarnessMD/munder-difflin](https://github.com/HarnessMD/munder-difflin) | ~9k | "Run an office of claude-code/codex agents" |
| [smtg-ai/claude-squad](https://github.com/smtg-ai/claude-squad) | ~9k | Manage multiple AI terminal agents in isolated workspaces |

## Feature decisions

### Adopted (this round of work)

| Feature | Who has it | What we built | Why it fits |
|---------|-----------|---------------|-------------|
| One-command adoption into any project | BMAD (`npx bmad-method install`), OMC plugin/npm install | `orchestration.json` config + `scripts/init.sh` scaffolder + `templates/`; every script now reads roles from config | Our scripts had the live workspace's paths hardcoded in six places. Nothing is reusable until roles/repos/axes are data, not code. |
| Completion/failure notifications | OMC (Telegram/Discord/Slack stop-callbacks), ruflo | `hooks/on-{start,reply,fail}.d/` fired by `relay.sh`, with a webhook example (`hooks/README.md`) | Dispatches run 20–60 min unattended. The human should get a ping, not babysit a dashboard. Plain shell hooks beat a notification subsystem: anything scriptable works. |
| Doctor / deep health check | OMC `/omc-doctor` | `scripts/doctor.sh`: env, config, registry consistency, ledger hygiene, suspicious dispatches, hook syntax, failure history | `relay --check` validated setup only. Most of our first-run pain (dead dispatches, registry mismatch) is detectable in one command. |
| Cost & usage analytics | OMC analytics/cost tracking, ruflo monitoring | `scripts/stats.sh [--daily\|--json]` parsing `activity.log` | We already logged per-relay tokens/durations (R22 demanded hand-counting at close-out). Aggregating a log is 100 lines of bash. |
| Automated liveness watchdog | ruflo health monitoring, OMC `omc wait` | `scripts/watchdog.sh` (+ `--auto-orphan` writing R18 markers, 60-min safety threshold) | R18 made liveness an orchestrator *duty*; the first live run burned an hour on a dead dispatch showing RUNNING. The check is mechanical — so it's a tool now (R28). |
| Transcript/session search | OMC `session search` | `scripts/search.sh [-r role] <pattern>` | An audit trail you can't search is a write-only log. Plain files + grep = zero-index search that can't drift. |
| Verify→fix loop on gate failure | OMC team-verify/team-fix, BMad Loop | R26 in `rules/RULES.md`: `GATES: fail` auto-re-dispatches with fix instruction, max 2 retries, then `blocked` | Judgment encoded as a rule instead of hoping the orchestrator re-dispatches consistently. Bounded retries because infinite fix loops burn tokens silently. |
| Right-sized intake / clarify-first | BMAD "Clarify" phase + size-to-work, OMC deep-interview | R25: vague requests get one clarifying round with the user before dispatch | A vague intake wastes a role session's context — our scarcest resource. One round, not an interview ceremony. |
| Contract artifact verification | (nobody — our gate) | `scripts/contract-check.sh`: exact → repo-rooted → fuzzy resolution (encodes R24) | Earned in run #1: a stated path that missed by one directory almost failed the contract gate. Now it's mechanical. |
| OSS furniture | BMAD, OMC (MIT, CHANGELOG, CONTRIBUTING, docs) | LICENSE, CHANGELOG.md, CONTRIBUTING.md, docs/ | Nobody adopts an undocumented workspace. |

### Adopted (round 2 — v0.4.0, 2026-11-05)

| Feature | Who has it | What we built | Why it fits |
|---------|-----------|---------------|-------------|
| Multi-harness roles (Claude + Codex + anything, per task) | agent-orchestrator (35+ tools), Vibe Kanban, codex-orchestrator (Claude coordinates, Codex executes) | per-role `harness`/`model`/`args` in `orchestration.json`; relay adapters for zcode/claude/codex + custom bins; one shared envelope decoder | The ledger contract (transcripts, sessions, tasks, recovery) is harness-agnostic — swapping the CLI per role costs one config line. |
| Git worktree isolation per agent | claude-squad, OMC worktree mode, native Claude agent teams — "table stakes" by Aug 2026 | `"worktree": "auto"` per role: created once on `orch/<role>`, reused | One flag instead of a worktree manager: the worktree is just the role's dispatch cwd. |
| Task → merged-PR loop | agent-orchestrator ("task to merged PR"), gh-skills, review-agent gates | `hooks/on-reply.d/open-pr.sh.example` (gh PR on STATUS done + BRANCH) + reviewer-role pattern | The loop's decisions stay in the rules; the mechanical step (gh pr create) is a hook. |
| Telegram notifications | OMC (Telegram/Discord/Slack callbacks) | `notify-telegram.sh.example` hook | Same relay-hook surface as the webhook notifier — one curl. |
| Ledger auto-commit | state-versioning orchestrators | `"auto_commit": true` commits the ledger after every reply | Audit trail stays pushed with zero ceremony. |

### Already had (our differentiators — kept and doubled down)

- **Ledger as the only shared state** — durable context BMAD advocates, but
  as plain files: feature lifecycle, verbatim transcripts, session
  registry, heartbeats, activity log. Auditable with `cat`; searchable
  with grep; no database, no server.
- **Overlap check / conflict negotiation** (R4–R7) — none of the surveyed
  projects structurally prevent two agents from colliding on the same API
  surface; they parallelize and hope. This is the reason this workspace
  exists.
- **Session-per-repo role agents** — each role's session loads its repo's
  own conventions natively (BMAD/OMC inject prompts into one context;
  claude-squad isolates workspaces per *task* but has no repo-anchored
  roles).
- **Failure archaeology** (R17/R23): orphan markers, salvage-first
  re-dispatch, freeze-the-runner, decode-the-envelope — earned from a real
  dead-relay incident and recovered work.
- **Learning loop** (R13/R14 → now R28): every run appends lessons; rules
  applied mechanically three times become tools. ruflo advertises
  "self-learning memory"; ours is reviewable prose in git.
- **Observability**: browser topology GUI + terminal dashboard + TUI
  inspection of the *actual* agent session — comparable to OMC's HUD /
  agent-orchestrator's supervisor UIs, zero dependencies.

### Deliberately skipped (still, after v0.4)

| Feature | Who has it | Why we skip it |
|---------|-----------|----------------|
| Vector / neural shared memory, swarm topologies, hive-mind consensus | ruflo | For 2–6 long-lived role agents with a git-committed ledger, cosine similarity is a solution looking for a problem; consensus is what the overlap check does in one comparison. (ruflo's marketing also outruns its code — verify before envying.) |
| Desktop/mobile supervisor apps, dashboards-as-a-service | agent-orchestrator, Vibe Kanban | A zero-dependency browser page and a terminal dashboard cover a single-team workflow; a GUI app is a maintenance liability. |
| Full agile ceremony (PRD/planning agent pipelines) | BMAD, OMC team pipeline | The orchestrator IS an agent with judgment + AskUserQuestion; workflow-as-prose (AGENTS.md) adapts per team, workflow-as-pipeline ossifies. We encode what repeats into rules/tools instead. |
| Rate-limit auto-resume daemon | OMC `omc wait` | The watchdog + orphan protocol covers the failure we actually hit. A daemon is another thing that can die silently. |

## The honest one-line summary

The big frameworks optimize **many agents on one machine**; this workspace
optimizes **a few agents on real repos that must not collide** — and stays
inspectable: every decision is a line in a file you can read in a year.
