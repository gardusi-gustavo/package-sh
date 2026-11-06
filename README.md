# shell-bash

Cross-repository shell automation, published as a versioned package and driven
by the `sb` runner.

## Install

Pin a tag. Do not use `main`.

```bash
curl -fsSL \
  "http://gitea:3000/packages/shell-bash/raw/tag/v0.1.0/bin/sb" \
  -o /tmp/sb
chmod +x /tmp/sb
/tmp/sb verify
```

## Use

```bash
/tmp/sb list
/tmp/sb run ci.validate --root .
/tmp/sb run release --version 0.1.0 --root .
```

Scripts receive configuration through arguments and the environment. They do
not source files from `packages/templates`.

## Layout

```text
bin/sb                    runner and fetcher
infra/scripts/            canonical shell scripts
tests/fixtures/           validator fixtures
dist/manifest.json        script paths and checksums
```

## Release

A release is a Git tag plus a Gitea release containing the repository archive
and `dist/manifest.json`. Consumers pin the tag and verify checksums.
