# Orchestration rules

The playbook for the orchestrator. Seeded on 2026-11-05 from the design
session that built this workspace; **every feature run must add what it
learned** — this file is how Level 1 extracts the rules that a Level 2
workflow will later encode.

Rules are phrased generically (not per-feature). Append-only: a bad rule is
superseded by a new dated rule that says so, never edited in place.

## Concurrency

- **R1 — Backend is single-writer.** One backend work item in flight at a
  time; everything else waits in `backend-queued`. Two parallel backend
  changes touching the same API surface is where mistakes are made.
- **R2 — One in-flight session per repo.** Never relay a second task to a
  role that hasn't finished its current one; queue it. (If same-repo
  parallelism ever becomes necessary: one session per git worktree.)
- **R3 — Fronts may run in parallel with each other.** Different repos, no
  shared code — they can only collide via the backend contract, which R4
  guards.

## Conflict detection

- **R4 — Overlap check before ANY backend dispatch.** Compare the request
  against every ledger entry in `backend-in-flight` / `contract-published` /
  `front-applying`, across four axes: endpoints, schemas/DTOs, permissions,
  EF migrations.
- **R5 — Duplicate or subset → reject and redirect.** Don't start parallel
  work; point the requesting agent at the in-flight feature's contract and
  have it build on that.
- **R6 — Partial overlap → negotiate.** Tell the second agent exactly what
  the in-flight feature already covers, have it re-scope its request to the
  residual need, and queue that behind the in-flight work.
- **R7 — The race that started all this:** a request arriving *while backend
  is mid-implementation* is handled the same as R4–R6 — the ledger's
  in-flight entry (not memory, not chat) is what makes the collision visible.

## Boundaries & communication

- **R8 — Session-per-repo.** Each role agent is a persistent session rooted
  in its own repo (`--cwd`), so its AGENTS.md, skills, and hooks load
  natively. The orchestrator never edits product repos; it only relays
  messages and reads repos read-only (proposals, contract notes, branches).
- **R9 — Durable state lives in the ledger only.** Messages carry summaries
  + file paths, never long histories. Context is precious; files are cheap.
- **R10 — Role replies end with the structured block** (STATUS / BRANCH /
  CHANGED / CONTRACT-or-PROPOSAL / GATES / NEXT). The orchestrator parses
  it; a reply without it is incomplete — ask again.

## Judgment

- **R11 — Product decisions escalate to the human.** Rejecting or reshaping
  a request, priority between queued features, breaking a published
  contract — ask, don't decide. Routine rulings already covered by a rule
  here can be made alone and logged.
- **R12 — Trust gates, verify artifacts.** A role reporting `GATES: pass`
  is normally trusted, but a contract note's file path is verified to exist
  before `contract-published`, and swagger/mock sync is spot-checked on the
  first few runs.

## Learning loop (the point of Level 1)

- **R13 — After every feature reaches `done` or `blocked`, append what the
  run taught:** what surprised the orchestrator, which rule was missing,
  which rule was wrong. Format: `- <YYYY-MM-DD> FEAT-… — <lesson>`, and if
  it generalizes, promote it to a numbered rule.
- **R14 — When a rule has been applied mechanically three times without
  escalation, it is ready for Level 2** (a workflow gate, not a judgment).

## Reliability — promoted from the first live run (2026-11-05, FEAT-20261105-tour-settings-tab)

- **R15 — Relay messages carry short ASCII pointers only.** All task detail
  lives in the ledger file, passed with `-f`/attach. Persian text in relay
  command-line arguments risks mojibake and bloats chat context (R9).
- **R16 — Front-led features are valid.** When a feature starts as frontend
  work (UI moves, renames, mocks over existing APIs), status is
  `front-applying`; the backend queue entry is created only when a proposal
  actually lands. The lifecycle is backend-centric *for backend work*, not
  as a gate for front work.
- **R17 — Re-dispatch after a dead relay says so.** The dispatch message
  must tell the new session: "a previous attempt died mid-work; committed or
  uncommitted partial work may exist on the branch — audit and salvage it
  before redoing anything." (On the first run this recovered a full
  session's work at zero redo cost.)
- **R18 — Liveness duty while a relay runs.** The orchestrator periodically
  checks each in-flight relay's last-output age (dashboard / watch). Silent
  > 15 min → verify the process is alive. If dead: write an orphan
  `-reply.md` marker on its transcript (keeps in-flight detection truthful),
  then decide re-dispatch per R17. Never leave a dead dispatch showing as
  RUNNING.
- **R19 — One in-flight relay per role is machine-enforced.** `relay.sh`
  refuses a dispatch while the role has an un-replied transcript (dead or
  alive); `--force` overrides knowingly; dead dispatches must be
  orphan-marked first. Two headless writers on one session/repo is the
  failure mode this exists to prevent.
- **R20 — Shell boundaries.** `relay.sh`/`inspect.sh` run only under Git
  Bash on Windows (they drive the Windows ZCode CLI and its machine-local
  session store; WSL bash would split it). `watch.sh`/`dashboard.sh` run
  anywhere. The orchestrator's own ZCode session satisfies this by default.
- **R21 — Readiness ping before the first real dispatch** on a new machine
  or after a ZCode app/CLI update: one cheap round-trip ("reply ACK, change
  nothing") catches CLI-path drift, session-store problems, and login
  expiry before they eat a real task.
- **R22 — Close-out records cost.** From `ledger/activity.log`: relay
  count, wall time, and token totals per feature — the budget data Level 2
  will need for planning.

### Run log — lessons (R13)

- 2026-11-05 FEAT-20261105-tour-settings-tab — first live run: a relay
  died on ~20 retryable provider API errors without replying; it showed as
  RUNNING for over an hour until the process list proved it dead (→ R18,
  R19; orphan-marker pattern; last-output-age in watch/dashboard). The
  re-dispatched session salvaged the dead one's uncommitted work (→ R17).
  Heartbeats proved the live channel once the briefing rule reached the
  session (reminder needed for pre-existing sessions). CMD's default `bash`
  turned out to be WSL, not Git Bash (→ R20, env-detecting lib.sh).

## Reliability — promoted from FEAT-20261105-tour-settings-tab close-out

- **R23 — Freeze the runner.** Dispatches execute a frozen snapshot copy of
  `relay.sh` (`cp` to a scratch path, run that), because bash parses scripts
  incrementally and a script re-saved mid-run aborts with bogus syntax
  errors at lines that are valid on disk — after the CLI already finished.
  Corollary: the relay wrapper's exit code is not the agent's outcome.
  Before declaring a dispatch dead, decode its `-json` envelope and check
  heartbeats — both "crashed" dispatches in the first run held complete
  replies (recovered at zero redo cost). The working tree is the shared
  state that makes salvage possible (ties into R17).
- **R24 — Contract-gate checks resolve artifact paths, they don't string-match
  them.** A role's reply may state a path relative or abbreviated (reply said
  `exports/…`, the file lived at `Docs/frontend/exports/…`). When a stated
  path misses, search under the stated root before failing the gate — a
  false gate failure would wrongly send the feature to `negotiating`.

## Research-promoted rules (2026-11-05)

Cross-checked against the top open-source orchestration frameworks
(BMAD-METHOD, ruflo/claude-flow, oh-my-claudecode, agent-orchestrator,
claude-squad — see `docs/COMPARISON.md`). These rules are **designed-in
from research**, not earned in a live run; each cites what the mature
frameworks do. They graduate to normal rules after their first live
application confirms them (R13 discipline applies).

- **R25 — Right-size the intake.** A request the orchestrator fully
  understands dispatches immediately; a vague one gets ONE clarifying round
  with the user (AskUserQuestion) before it spends a role's context.
  (BMAD's "Clarify" phase / "the process sizes itself to the work";
  oh-my-claudecode's deep-interview.) Small changes must not pay a
  ceremony tax; big ones must not start on guesses.
- **R26 — Gate failures re-dispatch automatically, bounded.** A reply
  ending `GATES: fail` (or naming a failing gate) is re-dispatched with a
  fix instruction without asking the user — max 2 automatic retries, then
  `blocked` with the transcript trail. (OMC's team-verify/team-fix loop;
  BMad Loop's build-verify-retro.) The ledger logs every retry.
- **R27 — Long unattended dispatches notify, they don't get watched.**
  Runs of 20+ minutes should have a hook enabled
  (`hooks/on-reply.d/`, `hooks/on-fail.d/` — webhook/Telegram/etc., see
  `hooks/README.md`) so completion/failure reaches the human without them
  babysitting `watch.sh`. (Every mature platform ships stop-callback
  notifications.) The orchestrator suggests this at dispatch when no hook
  is enabled.
- **R28 — Tool the rules.** When a rule is applied mechanically three
  times (R14's threshold), encode it as a script instead of orchestrator
  judgment: R18 → `scripts/watchdog.sh`, R24 →
  `scripts/contract-check.sh`, R22 → `scripts/stats.sh`. Judgment scales
  worse than code; the ledger records that the tool ran.

### Run log — close-out lessons (R13, cont.)

- 2026-11-05 FEAT-20261105-tour-settings-tab — close-out: both wrapper
  crashes were self-inflicted (relay.sh re-saved mid-execution), while the
  agents completed fine — R23 captures freeze-the-runner + decode-envelope;
  the R17 salvage worked because dispatch #2 audited before redoing (worth
  keeping in every re-dispatch message). Artifact-path drift cost one false
  alarm at the contract gate (→ R24). A non-blocking product question
  (divisions permission category) survived into `done` as a ledger open
  question — close-out may park questions for the human, it must not drop
  them. Full-loop cost: 6 relays, ~180 min agent wall time, ~42M input /
  ~170K output tokens (mostly cache reads) — see the feature's Close-out.

## Tooling milestones — rules that became code (R28)

- 2026-11-05 v0.3.1 — R23 (decode the envelope before declaring a dispatch
  dead) and R17 (the salvage notice on re-dispatch) are now machine-enforced:
  `watchdog.sh --auto-orphan` recovers a complete reply from the raw
  envelope (transcript written, session recorded, END (recovered) logged,
  task returned) and only orphans when the envelope is incomplete;
  `relay.sh --salvage` injects the R17 message. The orchestrator's judgment
  steps in a crash are now: run the watchdog, read its output, dispatch.
