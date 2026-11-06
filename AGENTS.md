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
- `kapetim` authors and `kapetao` reviews and merges.

## Validation

```bash
shellcheck infra/scripts/**/*.sh infra/scripts/*.sh
bash infra/scripts/ci/test-repo-contract.sh
```
