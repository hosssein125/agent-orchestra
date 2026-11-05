# Contributing

This repo is both a **live coordination workspace** and a **reusable
pattern** — contributions should improve the second without breaking the
first.

## Ground rules

- Plain files, plain bash, zero runtime dependencies beyond bash + node +
  the agent CLI. A new script must degrade gracefully (see `lib.sh`'s
  node-less helpers) and run under Git Bash on Windows.
- The ledger is append-only history: never rewrite `ledger/messages/` or
  `activity.log`; features close, they don't get edited into shape.
- `rules/RULES.md` is append-only and honest: a rule from a live run says
  so, a rule from research says so (see the research-promoted section).
  Bad rules are superseded, never edited in place.
- Scripts encode rules (R28): if your contribution replaces orchestrator
  judgment with a tool, note which rule it tools.

## Practical checklist

1. `bash -n scripts/*.sh` passes; `node --check scripts/graph-server.js`.
2. `bash scripts/relay.sh --check` and `bash scripts/doctor.sh` pass.
3. `bash scripts/init.sh --target /tmp/t --name t --roles a=<existing repo>`
   scaffolds, and the scaffold's own `relay.sh --check` passes.
4. A one-frame dashboard render works:
   `DASH_ONCE=1 DASH_VIEW=7 bash scripts/dashboard.sh`.
5. Update `CHANGELOG.md` and, if you touched the workflow, `AGENTS.md` /
   the matching template in `templates/` (they must not drift).

## The most valuable contributions

- **Run reports**: use it on your repos, then append what you learned to
  the rulebook (a PR that only adds run-log lessons is a good PR).
- New hook examples (Telegram bot, desktop toast, CI trigger) — small,
  dependency-free scripts in `hooks/*.d/`.
- Ports of the relay to other headless CLIs: keep the transcript/guard/
  envelope-decode contract identical; that contract IS the architecture.
