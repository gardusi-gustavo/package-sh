# sh
Cross-repository shell automation, published as a versioned package and driven
by the `sb` runner.

## Install

Pin a tag. Do not use `main`.

```bash
curl -fsSL \
  "https://raw.githubusercontent.com/gardusi-gustavo/package-sh/v0.7.7/bin/sb" \
  -o /tmp/sb
chmod +x /tmp/sb
/tmp/sb verify
```

## Use

```bash
/tmp/sb list
/tmp/sb run ci.validate --root .
/tmp/sb run release --root .
```

Scripts receive configuration through arguments and the environment. They do
not source files from `package-sh`.

## Dependencies

Each consumer pins only what it uses:

```bash
./bin/sb deps install --root .
./bin/sb deps check --root .
./bin/sb deps update templates/yml
```

## Layout

```text
bin/sb                    runner and fetcher
infra/scripts/            canonical shell scripts
hooks/                    Git hooks installed by scripts/install-hooks.sh
scripts/                  install-hooks.sh, init-repo.sh, pr-limit, pr-size
tests/fixtures/           validator fixtures
dist/manifest.json        script paths and checksums
```

## Release

A release is a Git tag plus a GitHub release containing the repository archive
and `dist/manifest.json`. Consumers pin the tag and verify checksums.
