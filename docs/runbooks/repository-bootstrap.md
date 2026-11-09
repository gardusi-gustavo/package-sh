# Repository bootstrap

Status: **staged locally**. GitHub-side rulesets and secret scanning are applied
by `devops/infra/scripts/github/bootstrap.sh` after the mirror exists.

## Baseline

- Default branch: `main`
- Merge: squash only; linear history; delete branch after merge
- Required review: 1 human approval
- Force push and branch deletion: denied
- Tags: `v*` protected
- Secret scanning and push protection: GitHub native
- Dependabot: `.github/dependabot.yml`
- Code owners: `.github/CODEOWNERS`
- Public repositories carry public data only
- Ingested data lives in `gardusi-gustavo/database` and arrives by PR

## Machine record

See `infra/config/bootstrap.json`.

```json
{
  "repository": "gardusi-gustavo/package-sh",
  "default_branch": "main",
  "required_approvals": 1,
  "squash_merge": true,
  "linear_history": true,
  "secret_scanning": "pending",
  "tag_pattern": "v*"
}
```
