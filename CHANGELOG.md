# Changelog

All notable changes to this orchestration. Format per Keep a Changelog;
this project does not yet promise semver — the pattern ships as one piece.

## [0.4.0] — 2026-11-05

Multi-harness roles, worktree isolation, and visual docs — driven by a
second research round over the 2026 orchestrator landscape (see
`docs/COMPARISON.md` § round 2).

### Added
- **Multi-harness relay**: every role picks its own harness in
  `orchestration.json` — `zcode` (default), `claude`, `codex`, or a custom
  bin via `"harnesses"`. Per-role `model` and extra `args`; permission
  modes map per harness; attachments inline for non-native CLIs.
- `scripts/envelope.js` — one tolerant envelope decoder for all harness
  shapes (zcode/claude single JSON, codex JSONL), shared by relay, watchdog
  recovery, and tests.
- **Per-role worktree isolation** (`"worktree": "auto"` or explicit path):
  created once on `orch/<role>`, reused; parallel same-repo work (the
  claude-squad/agent-teams pattern) as one config flag.
- **Ledger auto-commit** (`"auto_commit": true` / `ORCH_AUTO_COMMIT=1`):
  coordination repo commits the ledger after every reply.
- Hook examples: Telegram notifier and open-PR (`gh` on STATUS done +
  BRANCH) — the task→PR loop.
- Visual docs: animated GIF of live task flow + graph/panel/dashboard
  screenshots (`docs/assets/`), README badges and gallery.
- `scripts/init.sh --default-harness` + `name=path@harness` role specs.
- Config parser is brace-aware: pretty-printed (hand-edited) JSON with
  multi-line role objects parses correctly.
- `scripts/_test-harness.sh` — e2e harness suite with fake zcode/claude/
  codex CLIs (dispatch, sessions, task moves, worktree create/reuse,
  auto-commit).

### Changed
- `relay.sh --check` / `doctor.sh` validate each role's harness bin;
  `inspect.sh` attaches per-harness (`claude --resume`, `codex resume`).
- Activity START lines record `harness=…`.

## [0.3.1] — 2026-11-05

Crash recovery fully machine-enforced (closes the last two runbook-only
steps of the failure protocol).

### Added
- `watchdog.sh` now decodes the raw CLI envelope of every open dispatch
  before declaring death (R23). A complete envelope → classified
  `RECOVERABLE`, and `--auto-orphan` **recovers** it: writes the reply
  transcript from the envelope, records the session id, appends
  `END (recovered)` to `activity.log`, and returns the task to the
  orchestrator — no re-dispatch, zero redo. Incomplete envelope → the
  existing R18 orphan marker.
- `relay.sh --salvage` — prepends the R17 notice ("a previous attempt died
  mid-work; committed or uncommitted partial work may exist on the branch —
  audit and salvage before redoing") to any re-dispatch after a dead relay;
  also defaults the task-move reason.

## [0.3.0] — 2026-11-05

Task flow, graphically: features are now live tasks in the topology GUI.

### Added
- `ledger/tasks.json` — task movement log: per task a `holder` and a
  `history` of moves `{t, from, to, why}` since intake.
- `relay.sh --task <id>` / `--why "<reason>"` — movements are auto-logged
  on dispatch (`orchestrator → role`, with the reason), on reply
  (`role → orchestrator`, reason = the reply's first line), and on failure;
  the task id is inferred from a `-f FEAT-*.md` attach when `--task` is
  omitted.
- `scripts/task.sh` — `new` (intake hop `user → orchestrator`), `move`
  (manual hand-offs with reasons), `set` (status/title), `show`, `list`.
- Graph GUI task flow: an amber task token travels along the connector
  while its relay is in flight (looping) and returns to the orchestrator
  when the reply lands; task chips under each node list what it holds
  (orchestrator included — its queue is visible); clicking any task — chip,
  token, or features-list row — opens a panel with duration since creation
  and the full move history, every hop with its own reason.
- `doctor.sh` validates `tasks.json`; `init.sh` scaffolds it.

## [0.2.0] — 2026-11-05

Made the orchestration adoptable by any project, plus the ops features the
top open-source orchestrations proved out. Driven by a cross-framework
survey (BMAD-METHOD, ruflo, oh-my-claudecode, agent-orchestrator,
claude-squad) — see `docs/COMPARISON.md`.

### Added
- `orchestration.json` — config file (project, roles→repos, overlap axes,
  contract-note root); all scripts now read roles from it; without it they
  fail fast with a pointer to `init.sh --here`.
- `scripts/init.sh` — scaffold a new coordination workspace for any set of
  repos (interactive or flags), seeded with the earned rulebook; `--here`
  mode (re)writes this repo's config.
- `templates/` — AGENTS.md / role-briefing / ledger / README templates the
  init script renders.
- Relay hooks: `hooks/on-{start,reply,fail}.d/*.sh` fired by `relay.sh`
  with an `ORCH_*` environment; webhook notifier example for
  Discord/Slack/generic (`hooks/README.md`).
- `scripts/doctor.sh` — deep health check (env, config, registry, ledger
  hygiene, hooks, failure history).
- `scripts/watchdog.sh` — automated R18 liveness (ALIVE / VERIFY /
  DEAD-SUSPECT; `--auto-orphan` writes orphan markers past the 60-min
  safety threshold).
- `scripts/stats.sh` — per-role/day cost report from `activity.log`
  (`--daily`, `--json`); replaces hand-counting at close-out (R22).
- `scripts/search.sh` — full-text search over transcripts, heartbeats,
  feature files (`-r <role>` filter).
- `scripts/contract-check.sh` — contract-gate artifact resolution (exact →
  repo-rooted → fuzzy), encoding R24.
- Rules R25–R28 (right-sized intake, bounded gate-failure re-dispatch,
  notify-don't-watch, tool-the-rules) — research-promoted, labeled as such.
- Docs: README (adopt-your-project quickstart), `docs/ADOPTION.md`,
  `docs/COMPARISON.md`, `docs/ARCHITECTURE.md`; LICENSE (MIT),
  CONTRIBUTING, this changelog.

### Changed
- `relay.sh` / `inspect.sh` / `watch.sh` / `dashboard.sh` /
  `graph-server.js` are role-agnostic (config-driven); dashboard graph,
  header and inspect menu render N agents; ZCode CLI resolution tries
  `$ZCODE_CLI` → per-user install path → PATH (`find_cli`). A fresh clone
  without `orchestration.json` now fails fast with a pointer to
  `init.sh --here` instead of assuming any hardcoded layout.

### Fixed
- `watch.sh status` crashed on `local` outside a function at the repos
  panel (pre-existing; surfaced once the panel was reached reliably).

## [0.1.0] — 2026-11-05

First live loop (FEAT-20261105-tour-settings-tab): relay + transcripts,
ledger lifecycle, sessions registry, heartbeats, activity log, watch /
dashboard / graph GUI / TUI inspect, rules R1–R24 including the dead-relay
salvage protocol (R17/R18/R19), freeze-the-runner (R23), and contract-gate
path resolution (R24).
