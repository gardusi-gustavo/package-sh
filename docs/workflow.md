# Workflow step executor

`infra/scripts/workflow/step.sh` is one self-contained executor for the vault
and backup step contracts in `packages/json-schema`.

## Dispatch

The runner sets `SB_SCRIPT_NAME` before executing a script:

```bash
sb run vault.scan --input scan.json --dry-run
sb run backup.preflight --config backup-policy.json --json
sb run vault.transform --input item.json --root .
```

`step.sh` maps the name to a handler by replacing `.` and `-` with `_`:
`vault.scan` → `vault_scan`, `backup.verify_copy` → `backup_verify_copy`.

## Common arguments

| Argument | Meaning |
| --- | --- |
| `--step NAME` | explicit step name; not needed through `sb` |
| `--root PATH` | repository or workspace root |
| `--config PATH` | policy or contract path |
| `--state PATH` | state file path |
| `--input FILE` | JSON input; stdin is used when omitted |
| `--output FILE` | JSON output; stdout is used when omitted |
| `--json` | suppress human logs |
| `--dry-run` | plan only; no writes |

## Vault steps

`vault.scan`, `vault.classify`, `vault.plan`, `vault.reconcile`,
`vault.render`, `vault.fetch`, `vault.transform`, `vault.verify`,
`vault.publish`, `vault.cleanup`.

The media steps require `ffmpeg`, `ffprobe`, `jq`, and `sha256sum`. They use a
H.264 / AAC / 720p short-side profile and `--dry-run` prints the exact plan.

## Backup steps

`backup.lock`, `backup.preflight`, `backup.quiesce`, `backup.dump`,
`backup.validate`, `backup.manifest`, `backup.archive`, `backup.test`,
`backup.copy`, `backup.verify_copy`, `backup.publish_copy`,
`backup.reconcile`, `backup.prune`, `backup.status`, `backup.resume`,
`backup.unlock`.

Service and dump commands are environment-driven so the generic package does
not encode a specific deployment:

| Variable | Used by |
| --- | --- |
| `BACKUP_STOP_COMMAND` | `backup.quiesce` |
| `BACKUP_START_COMMAND` | `backup.resume` |
| `BACKUP_DUMP_COMMAND` | `backup.dump` |
| `BACKUP_PASSWORD_FILE` | `backup.archive`, `backup.test`, `backup.verify_copy` |

## Safety

- `--dry-run` is read-only.
- Card publish uses `.part` then rename and verifies SHA-256.
- Cleanup removes a store copy only after the card hash matches.
- Backup pruning keeps the newest archive and the minimum count.
- No credentials are stored in the repository.

## Test

```bash
bash infra/scripts/ci/test-workflow.sh
bash infra/scripts/ci/self-test.sh
```
