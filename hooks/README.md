# Hooks — notifications & integrations on relay events

Long dispatches (20–60 min) run unattended; hooks are how the outside world
finds out what happened without watching the dashboard. This is the feature
the big orchestration platforms expose as Telegram/Discord/Slack callbacks —
here it's three directories of plain shell scripts; anything you can script,
you can hook.

## Events

`relay.sh` fires each event by running every `*.sh` in the matching dir
(alphabetically, best-effort: a failing hook never fails the relay, each is
capped at 20s). Scripts with other extensions — e.g. `.sh.example` — are
inert; rename to enable.

| Dir | Fires | When |
|-----|-------|------|
| `hooks/on-start.d/` | after the dispatch START line is logged | relay left for the agent |
| `hooks/on-reply.d/` | after the reply transcript + session id are recorded | agent answered |
| `hooks/on-fail.d/`  | when the CLI exits non-zero | dispatch failed |

## Environment (exported to every hook)

| Var | Meaning |
|-----|---------|
| `ORCH_EVENT`    | `start` / `reply` / `fail` |
| `ORCH_ROLE`     | role name dispatched to |
| `ORCH_REPO`     | that role's repo path |
| `ORCH_SESSION`  | session id (on start: previous id or `new`) |
| `ORCH_OUT_FILE` | the outgoing transcript (`ledger/messages/<role>-<stamp>-out.md`) |
| `ORCH_REPLY_FILE` | (reply) the reply transcript — tail it for the summary |
| `ORCH_JSON_FILE` | raw CLI envelope (reply/fail) |
| `ORCH_STDERR_FILE` | (fail) the CLI's stderr log |
| `ORCH_DURATION` | (reply) wall seconds |
| `ORCH_TOKENS_IN` / `ORCH_TOKENS_OUT` | (reply) usage from the envelope |
| `ORCH_RC`       | (fail) the CLI's exit code |
| `ORCH_MODE`     | (start) permission mode |

## Built-in examples (rename `.example` → `.sh` to enable)

| Hook | Does |
|------|------|
| `on-reply.d/notify-webhook.sh.example` | POSTs a one-line summary to a Discord/Slack/generic webhook (`hooks/notify.url` or `ORCH_NOTIFY_URL`) |
| `on-fail.d/notify-webhook.sh.example` | same, failure flavor |
| `on-reply.d/notify-telegram.sh.example` | Telegram message on reply/failure (`hooks/telegram.env` with `ORCH_TG_BOT_TOKEN`/`ORCH_TG_CHAT_ID`) |
| `on-reply.d/open-pr.sh.example` | task→PR loop: on `STATUS: done` + `BRANCH:`, opens a PR via `gh` in the role's repo |

Enable a webhook example:

```bash
cp hooks/on-reply.d/notify-webhook.sh.example hooks/on-reply.d/notify-webhook.sh
echo 'https://discord.com/api/webhooks/…' > hooks/notify.url   # gitignored
```

(or export `ORCH_NOTIFY_URL` instead of the file). Then verify:

```bash
bash scripts/doctor.sh          # hook syntax check
ORCH_EVENT=reply ORCH_ROLE=test bash hooks/on-reply.d/notify-webhook.sh
```

## Writing your own

Any executable-free `*.sh` works — it just reads `ORCH_*` and does its
thing: desktop toasts, Telegram bots, CI triggers, billing spreadsheets,
lights. Two rules: never write to the product repos, and treat the ledger
(`ORCH_OUT_FILE` etc.) as read-only from hooks.
