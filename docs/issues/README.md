# Local issues

Agent work for this repository is stored here as one JSON file per item.

The canonical schema and lifecycle are in
`packages/templates/docs/issues/README.md` and
`packages/templates/docs/issues/schema.json`.

Rules:

- `3.x` bugs, `2.x` documentation/chores, `1.x` features/refactors.
- one to six fractional digits, no trailing zero.
- exactly zero or one `status: active`.
- only the active file gets a native Gitea issue.
- owner-created native issues are not migrated automatically.

Validate with:

```bash
infra/scripts/ci/validate-local-issues.sh --root .
```
