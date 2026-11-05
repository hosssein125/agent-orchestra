# {{PROJECT}} coordination workspace

This is a coordination workspace built with the ledger-anchored multi-agent
orchestration pattern: an orchestrator session (open a ZCode session in this
directory) coordinating persistent role-agent sessions — one per repo — via
the headless CLI. Roles: {{ROLENAMES}}.

- `AGENTS.md` — the orchestrator runbook (auto-loaded by the orchestrator)
- `rules/RULES.md` — the playbook; grows after every feature run
- `orchestration.json` — roles → repo paths (what makes this workspace yours)
- `ledger/` — per-feature state, session registry, transcripts, heartbeats
- `prompts/role-*.md` — briefings handed to each role agent on first contact
- `scripts/` — relay / watch / dashboard / graph / doctor / stats / search
- `hooks/` — start/reply/fail notification hooks (see hooks/README.md)

## Quick start (human)

1. `bash scripts/relay.sh --check` — verify CLI, node, repos, registry.
2. `bash scripts/doctor.sh` — deeper health check.
3. Open a ZCode session here and describe a feature; the orchestrator takes
   it from there per `AGENTS.md`.
4. Watch: `bash scripts/dashboard.sh` (terminal), `bash scripts/graph.sh`
   (browser topology), `bash scripts/watch.sh live`.

The upstream project ships full docs: README, docs/ADOPTION.md,
docs/COMPARISON.md, docs/ARCHITECTURE.md.
