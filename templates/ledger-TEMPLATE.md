# FEAT-<YYYYMMDD>-<slug>

- Status: requested
- Requested by: <role | user>
- Created: <YYYY-MM-DD>
- Updated: <YYYY-MM-DD>

## Requests

| # | From | Date | Summary | State |
|---|------|------|---------|-------|
| 1 |  |  |  |  |

## Overlap check (run before ANY dispatch to the contract-owning role)

Compared against every ledger entry with status `backend-in-flight` /
`contract-published` / `front-applying`:

{{AXES_BULLETS}}
Verdict: <clean → start | duplicate/subset of FEAT-… → reject & point to its contract | partial overlap → negotiate>

## Contract deltas (the contract-owning role owns this section)

{{AXES_BULLETS}}
- Frontend note: {{CONTRACT_ROOT}}/<YYYY-MM-DD>-<slug>.md (in that repo)

## Decisions

- <YYYY-MM-DD> — <decision + one-line reason>

## Messages

| Date | To | Subject | Transcript |
|------|----|---------|-----------|
|  |  |  | ledger/messages/<role>-<stamp>-out.md |

## Sessions

- <role>: <see ledger/sessions.json>

## Open questions / escalations

- 

## Close-out

- Done date: 
- Gates passed (per role): 
- Cost (R22): <scripts/stats.sh output — relay count, wall time, tokens>
- Rules extracted (→ rules/RULES.md): 
