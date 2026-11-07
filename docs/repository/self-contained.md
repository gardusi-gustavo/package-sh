# Repository self-containment

**What this is:** the checklist for making this repository understandable,
recoverable, and copyable without Gitea.

## Source of truth

- Repository: `packages/shell-bash`
- Visibility: public
- Owner: `gardusi-gustavo`
- Git platform: Gitea
- Local checkout: `~/repos/packages/shell-bash`

## Durable data

- [x] `README.md` and `AGENTS.md`
- [x] `docs/README.md`
- [x] `docs/issues/`
- [x] decisions and operating rules in AGENTS
- [x] runbook and consumption examples
- [x] `VERSION`
- [ ] `CHANGELOG.md`
- [x] release tags
- [ ] `infra/config/repo.json`
- [ ] CI workflow
- [x] tests and self-test
- [x] external service references
- [x] backup and restore notes

## External-only data

- issues and comments: Gitea owner issues
- PR discussions: Gitea
- attachments and media: none
- secrets: none
- package registry artifacts: none
- external services: Gitea only

## Migration status

- [x] Agent-created issues migrated: none open
- [ ] Owner-created issues classified
- [ ] Closed history exported to backup
- [x] Wiki content not applicable
- [x] GitHub v1 issue created: #21

## Copy test

1. Clone the repository.
2. Read the script contract.
3. Run `bash infra/scripts/ci/self-test.sh`.
4. Fetch a pinned release through `bin/sb`.
