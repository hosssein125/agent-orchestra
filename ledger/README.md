# Ledger

The ledger is the **only shared state** in the whole orchestration. Sessions
are ephemeral and context-limited; the ledger is durable and auditable. If it
isn't written here, it didn't happen.

## Contents

- `FEAT-<YYYYMMDD>-<slug>.md` — one file per feature, created from
  `TEMPLATE.md`. Copy the template, never edit it.
- `sessions.json` — registry of the persistent role-agent session ids
  (`backend`, `admin-front`, `customer-front`). Managed by
  `scripts/relay.sh`; do not hand-edit unless a session must be invalidated
  (set the role to `null` to force a fresh session on the next relay).
- `messages/` — verbatim transcripts of every orchestrator↔role message:
  `<role>-<stamp>-out.md` (sent), `-reply.md` (received), `.json` (raw CLI
  envelope). Never delete; they are the audit trail and the raw material for
  rule extraction. An `-out.md` whose `-reply.md` doesn't exist yet is an
  **in-flight relay**.
- `activity.log` — one line per relay dispatch: START / END (with duration
  and token usage) / FAILED. Written by `scripts/relay.sh`; append-only.
- `heartbeats/<role>.md` — live progress lines written by the role agents
  themselves (one line per meaningful step). The raw material for
  `scripts/watch.sh live`.
- `tasks.json` — the task movement log behind the graph GUI's animated
  task tokens. One entry per feature: `title`, `status`, `holder` (who has
  it now: `orchestrator`, a role, or `user`), and `history` — every move
  `{t, from, to, why}` since intake. `relay.sh` appends movements
  automatically on dispatch/reply/fail (task inferred from a `-f FEAT-*.md`
  attach; `--why` overrides the dispatch reason; the reply's first line is
  the return reason). `scripts/task.sh new|move|set|show|list` covers the
  orchestrator-side moves (intake, manual hand-offs, status).

## Status values (feature lifecycle)

```
requested → analyzing → backend-queued → backend-in-flight
          → contract-published → front-applying → done
```

Any state may enter `negotiating` (conflict with another feature) or
`blocked` (needs a human decision or a dependency).

## Discipline

- One status per feature at a time; update `Updated:` on every change.
- Messages between agents carry **summaries + file paths**, never long
  histories — point at ledger files, don't paste them into chat.
- Decisions are logged with a reason, even (especially) when the orchestrator
  makes them alone.
