# Local tasks

**What this is:** the append-only task queue for this repository.

A task is one JSON file. The file is the task. No creator, platform, status, or
sync metadata.

The canonical schema and lifecycle live in
`templates/md/docs/issues/schema.json` and `templates/md/docs/issues/README.md`.

## Filename

```text
<rank>-<slug>.json
```

- rank is `1`, `2`, or `3`, followed by `.` and one to six digits
- no trailing zero: `3.1`, not `3.10`
- slug is lowercase letters, digits, and hyphens
- rank must be unique in the repository

## Rank

Higher fraction = more important.

| Rank | Type |
| --- | --- |
| `3.x` | Bug |
| `2.x` | Documentation or chore |
| `1.x` | Feature or refactor |

## Lifecycle

1. Append one or more task files in an intake PR.
2. Pick the highest-ranked task.
3. Open one work PR.
4. The PR references the task and deletes the file.
5. Merge completes the task.

```text
Task: docs/issues/3.1-fix-auth-token-leak.json
```

There is no native issue for agent work. Owner-created native issues remain
native and are outside this queue.

## Failed attempt

Append to `attempts` and keep the file.

## Validate

```bash
infra/scripts/ci/validate-local-issues.sh --root .
```
