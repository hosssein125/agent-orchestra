# Architecture

One orchestrator, N role agents, one ledger. Everything else is plumbing.

## Components

```
orchestration.json ── config: project name, roles→repos, overlap axes
        │
        ▼
scripts/lib.sh ──── shared lib: config loader (load_roles/role_repo),
        │            node/CLI resolution, env detection, hook runner
        ▼
scripts/relay.sh ── THE channel to role agents:
        │            headless CLI (zcode -p … --cwd <repo> --resume <sess>)
        │            • transcripts every message  → ledger/messages/
        │            • one-in-flight-per-role guard (R19)
        │            • activity log START/END/tokens/FAILED
        │            • session registry refresh
        │            • fires hooks on start/reply/fail
        ▼
ledger/ ─────────── the only shared state (plain files, git-committed)
  FEAT-*.md          per-feature lifecycle + overlap verdicts + decisions
  messages/          verbatim orchestrator↔role transcripts (+raw envelopes)
  sessions.json      role → session id (null = fresh next relay)
  heartbeats/        role agents append one line per meaningful step
  activity.log       one line per dispatch (append-only)
  tasks.json         task movement log: holder + every move {t,from,to,why}
        ▲
        │ read-only, every observer:
scripts/watch.sh ────────── snapshot / refresh / follow
scripts/dashboard.sh ───── full-screen terminal dashboard (7 views)
scripts/graph.sh + graph-server.js ── browser topology GUI (zero deps):
                        tasks as tokens animating along the edges while a
                        relay runs; task chips under nodes; click a task →
                        duration + full move history with reasons
scripts/inspect.sh ─────── attach the role's real session in the TUI
scripts/doctor.sh ──────── deep health check
scripts/watchdog.sh ────── liveness: ALIVE/VERIFY/DEAD-SUSPECT, orphan markers
scripts/stats.sh ───────── cost report from activity.log
scripts/search.sh ──────── grep across the whole ledger
scripts/contract-check.sh  fuzzy artifact-path resolution (contract gate)
scripts/task.sh ────────── task intake/move/status/show/list
scripts/init.sh ────────── scaffold a new workspace from templates/
```

## Dispatch lifecycle (one relay)

```
orchestrator session                 relay.sh                        role agent (headless)
───────────────────                 ─────────                        ────────────────────
message + attach ledger file ──▶ guard: role idle? (R19)
                                  transcript -out.md
                                  activity: START
                                  hooks: on-start
                                  run CLI ─────────────────────────▶ reads repo AGENTS.md,
                                                                       works, heartbeats →
                                                                       ledger/heartbeats/,
                                                                       replies w/ STATUS block
                                  parse envelope (R23:
                                  decode, don't trust exit code) ◀─
                                  transcript -reply.md
                                  activity: END + tokens
                                  session id refresh
                                  hooks: on-reply
process reply file ◀────────────── echo reply
update FEAT-*.md status
```

The orchestrator launches relays **in the background** and keeps working
(intakes, overlap checks) while they run — the concurrency this whole
design exists for. Front roles may be dispatched in parallel (R3); the
contract-owning role is single-writer (R1).

## Feature lifecycle

```
requested → analyzing → backend-queued → backend-in-flight
          → contract-published → front-applying → done
```

Any state may enter `negotiating` or `blocked`. Status lives in one place:
the FEAT file. If it isn't written there, it didn't happen.

## Failure model

- **In-flight detection is structural**: an `-out.md` without its
  `-reply.md`. No locks, no heartbeats needed to know a dispatch is open.
- **Decode before declaring death** (R23): `watchdog.sh` parses the raw
  CLI envelope of every open dispatch. A complete envelope means only the
  wrapper died — `--auto-orphan` then *recovers* the reply (writes the
  transcript from the envelope, records the session id, appends
  `END (recovered)` to the activity log, returns the task to the
  orchestrator). No re-dispatch, zero redo.
- **Liveness**: the CLI streams stderr; `watchdog.sh` reads its mtime.
  Silent ≥ 15 min → verify; silent ≥ 60 min with no complete envelope →
  `--auto-orphan` writes the marker that closes the dispatch (never let a
  dead one show RUNNING).
- **Re-dispatch carries the salvage notice** (R17): `relay.sh --salvage`
  prepends "a previous attempt died mid-work; committed or uncommitted
  partial work may exist on the branch — audit and salvage before redoing".
  The replacement resumes the same session and audits the working tree
  first. In run #1 this recovered a dead agent's work at zero redo cost.
- **The runner is frozen**: dispatches execute a snapshot copy of
  relay.sh, and the wrapper's exit code is not the agent's outcome — the
  envelope decoder in the watchdog is the machine-enforced half of that
  rule.

## Hooks

`relay.sh` runs every `hooks/<event>.d/*.sh` (alphabetical, 20s cap,
best-effort — a hook can never fail a relay) with an `ORCH_*` environment
describing the dispatch. The shipped example POSTs a summary to a webhook.
See `hooks/README.md`.

## Learning loop

Every close-out appends to `rules/RULES.md` (R13). A rule applied
mechanically three times becomes a tool (R28: watchdog, stats,
contract-check all started as rules). The rulebook is committed with the
ledger, so the orchestration's judgment survives sessions and machines —
and `scripts/init.sh` seeds new workspaces with it.

## Task flow (what the graph animates)

Every task is one entry in `ledger/tasks.json` with a `holder` and a
`history` of moves. `relay.sh` appends them automatically: dispatch logs
`orchestrator → <role>` with the `--why` reason (or the message head);
reply logs `<role> → orchestrator` with the reply's first line; failure
logs a failed move. The orchestrator adds the intake hop
(`user → orchestrator`) via `scripts/task.sh new` and any manual hand-offs
via `task.sh move`.

The graph server reads the file on every poll; the page detects
in-flight transitions and animates a token along the connector (looping
outbound while the relay runs, one-shot home when the reply lands). Click
any task — chip, token, or features-list row — for the duration and the
full move history, each hop with its own reason.

## Why plain files (and no server/database)

Every alternative — a state DB, a message bus, a daemon — adds a component
that can die, drift, or need locking. The ledger is concurrently readable
by every observer (dashboards just read files), append-safe for its
writers (one orchestrator + one line per heartbeat), diffable in git, and
auditable with `grep`. The first live run's postmortem was possible
*because* the raw envelopes were files on disk.
