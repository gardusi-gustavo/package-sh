# Security

## Reporting

Use GitHub private vulnerability reporting for `gardusi-gustavo/workflow-devops`.
Do not open a public issue for a secret exposure.

## Rules

- No secret is committed. Secrets live in `/etc/opencode/secrets/`, local env
  files, or GitHub Environments.
- Public repositories contain public data only.
- `private` is the only private repository. It is never mirrored to a public
  destination.
- Data ingestion into `database` uses PRs, human approval, and squash merge.
- Exposed credentials are rotated, removed from active use, and untracked. Git
  history is not rewritten.
