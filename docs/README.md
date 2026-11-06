# shell-bash docs

Each script is independent and argument-driven.

- `--root PATH` selects the target repository.
- `--config PATH` selects the contract file.
- `--json` emits machine-readable output where supported.
- `--dry-run` prevents writes where supported.

The `sb` runner resolves scripts from a tagged checkout or from the pinned
`dist/manifest.json`, verifies their SHA256, then executes them.
