# AGENTS.md

## Start here

- Read `README.md`.
- Read `docs/README.md`.
- Search open Gitea issues before starting.

## Rules

- Keep every script under `infra/scripts/`.
- Scripts accept `--root`, `--config`, `--version`, `--json`, and `--dry-run` where they make sense.
- Do not source files from another repository.
- Do not use mutable branches in consumer URLs.
- Pin releases by tag and verify checksums.
- Never put credentials in scripts, logs, or issues.
- Changes go through a branch and a pull request.
- `gardusi-gustavo-bot` authors and `gardusi-gustavo` reviews and merges.

## Validation

```bash
shellcheck infra/scripts/**/*.sh infra/scripts/*.sh
bash infra/scripts/ci/test-repo-contract.sh
```

## Local tasks

- Tasks live in `docs/issues/` as one JSON file per task.
- Append tasks; do not create native issues for agent work.
- Rank: `3.x` bugs, `2.x` documentation/chores, `1.x` features/refactors.
  Higher fraction = more important.
- Filename: `<rank>-<slug>.json`; no trailing zero; one to six fractional digits.
- The file is the task. There is no author, source, platform, or status field.
- Pick the highest-ranked task; one work PR per repository.
- The PR references the task and deletes the file:
  `Task: docs/issues/<file>.json`.
- Merge completes the task. Git history keeps the record.
- On a failed PR, append an attempt to the task file, close the PR, and keep the file.
