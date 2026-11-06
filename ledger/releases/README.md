# Release records (REL files)

Every release, hotfix, and rollback gets one file here:
`REL-<YYYYMMDD>-<vX.Y.Z>.md`. The **orchestrator** writes it as the release
order (it fixes the contents — the devops agent never chooses what ships);
the **devops agent** appends the outcome after executing. The file is
attached to the devops dispatch via `relay.sh devops -f` and is what
`scripts/release-check.sh` verifies the reply against.

## Release order (written by the orchestrator)

- `TYPE:` release | hotfix | rollback
- `MODE:` develop | features *(release only)*
  - `develop` — ship whole develop→main per repo; use when develop is
    exactly what should ship
  - `features` — ship ONLY the listed features, composed on a
    `release/<VERSION>` branch per repo, even when develop holds more
- `VERSION:` vX.Y.Z — SemVer: breaking contract change → at least minor;
  feature work → minor/patch; hotfix/rollback → patch bump of the bad tag
- `REPOS:` backend, admin-front, customer-front (hotfix: affected only)
- `FEATURES:` shipped FEAT ids + one line each (release only). In
  `features` mode, each feature also carries its per-repo sources,
  resolved by the orchestrator from the ledger (per-role `BRANCH:` lines)
  and PR state — `branch:<name>` while the PR is unmerged,
  `merged:<sha>` (the PR merge commit on `forti/develop`) once merged:

  | FEAT | repo | source |
  |------|------|--------|
  | FEAT-…-tour-settings | backend | merged:9f31ab2 |
  | FEAT-…-tour-settings | admin-front | branch:feature/tour-settings |
  | FEAT-…-divisions | backend | branch:feature/divisions |

- `BRANCH:` hotfix branch name (hotfix only)
- `PREV-GOOD:` previous known-good tag (rollback only)

Pairing constraints the orchestrator enforces when composing a
`features` order: a front-repo source ships only together with its
feature's backend part (in this release or already on main); a feature
whose migration builds on an unreleased migration forces a wider
selection or `MODE: develop`.

## Outcome (appended by the devops agent)

- per repo: merge commit, tag, pushed yes/no; sources actually used
- pending EF migrations (backend releases)
- back-port outcome: hotfix → develop | features-mode `branch:` sources
  → develop | n/a
- `ROLLED BACK → <new tag>` (rollback only)
- `STATUS:` released | rolled-back | failed
