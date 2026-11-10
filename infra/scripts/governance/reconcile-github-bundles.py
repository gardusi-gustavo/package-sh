#!/usr/bin/env python3
"""Reconcile live GitHub repositories with local Git bundles and tag bundles."""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

DEFAULT_ORDER = Path(
    "/home/user/repos/gardusi-gustavo/contract-json/governance/bundle-order.json"
)
DEFAULT_ROOT = Path("/srv/backup/git-bundles")
DEFAULT_OUT = Path("/srv/backup/reconciliation")
PASSFILE = Path("/srv/backup/secrets/backup.pass")


def run(cmd: list[str], *, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, check=check)


def gh_json(path: str):
    result = run(["gh", "api", path])
    return json.loads(result.stdout) if result.stdout.strip() else None


def gh_list(path: str) -> list:
    result = run(["gh", "api", "--paginate", path, "--jq", ".[]"])
    return [json.loads(line) for line in result.stdout.splitlines() if line.strip()]


def list_heads(bundle: Path) -> dict[str, str]:
    result = run(["git", "bundle", "list-heads", str(bundle)], check=False)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or f"cannot read {bundle}")
    refs = {}
    for line in result.stdout.splitlines():
        parts = line.split(maxsplit=1)
        if len(parts) == 2:
            refs[parts[1].strip()] = parts[0]
    return refs


def bundle_heads(bundle: Path) -> dict[str, str]:
    if not bundle.name.endswith(".gpg"):
        return list_heads(bundle)
    if not PASSFILE.is_file():
        raise RuntimeError(f"encrypted bundle without passphrase: {bundle}")
    with tempfile.TemporaryDirectory(prefix="reconcile.") as tmp:
        plain = Path(tmp) / "snapshot.bundle"
        result = run(
            [
                "gpg",
                "--batch",
                "--yes",
                "--decrypt",
                "--passphrase-file",
                str(PASSFILE),
                "--output",
                str(plain),
                str(bundle),
            ],
            check=False,
        )
        if result.returncode != 0 or not plain.is_file():
            raise RuntimeError(result.stderr.strip() or f"cannot decrypt {bundle}")
        return list_heads(plain)


def bundle_state(root: Path, repo: str) -> dict:
    manifest_path = root / repo / "manifest.json"
    if not manifest_path.is_file():
        raise RuntimeError(f"missing manifest: {manifest_path}")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    latest = manifest.get("latest_snapshot")
    if not latest:
        raise RuntimeError("manifest has no snapshot")
    snapshot = root / repo / latest
    refs = bundle_heads(snapshot)
    head = refs.get("refs/heads/main") or refs.get("HEAD")
    if not head:
        candidates = sorted(set(refs.values()))
        if len(candidates) != 1:
            raise RuntimeError(f"ambiguous snapshot head: {sorted(refs)}")
        head = candidates[0]
    tags = sorted(
        {
            entry["tag"]
            for entry in manifest.get("bundles", [])
            if entry.get("kind") == "tag" and entry.get("tag")
        }
    )
    return {"head": head, "latest_snapshot": latest, "tags": tags}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--order", type=Path, default=DEFAULT_ORDER)
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT)
    parser.add_argument("--out-dir", type=Path, default=DEFAULT_OUT)
    args = parser.parse_args()

    order = json.loads(args.order.read_text(encoding="utf-8"))
    repos = [repo for tier in order["tiers"] for repo in tier["repos"]]
    rows = []
    failures = 0
    for repo in repos:
        row = {"repository": repo, "status": "ok", "errors": []}
        try:
            commit = gh_json(f"repos/{repo}/commits/main")
            if not commit:
                raise RuntimeError("GitHub returned no commit")
            gh_head = commit["sha"]
            bundle = bundle_state(args.root, repo)
            row.update(
                {
                    "github_head": gh_head,
                    "bundle_head": bundle["head"],
                    "latest_snapshot": bundle["latest_snapshot"],
                    "github_tree": commit["commit"]["tree"]["sha"],
                    "tree_check": "implied-by-sha",
                }
            )
            if gh_head != bundle["head"]:
                row["errors"].append("github-head != bundle-head")
            gh_tags = sorted(
                {item["name"] for item in gh_list(f"repos/{repo}/tags")}
            )
            missing = sorted(set(gh_tags) - set(bundle["tags"]))
            row.update(
                {
                    "github_tags": len(gh_tags),
                    "bundle_tags": len(bundle["tags"]),
                    "missing_tag_bundles": missing,
                }
            )
            if missing:
                row["errors"].append("missing tag bundles")
        except Exception as exc:  # noqa: BLE001
            row["status"] = "error"
            row["errors"].append(str(exc))
        if row["errors"]:
            if row["status"] == "ok":
                row["status"] = "mismatch"
            failures += 1
        rows.append(row)

    report = {
        "schema": 1,
        "kind": "github-bundle-reconciliation",
        "generated_at": datetime.now(timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z"),
        "order": str(args.order),
        "bundle_root": str(args.root),
        "summary": {
            "repositories": len(rows),
            "ok": sum(1 for row in rows if row["status"] == "ok"),
            "mismatch": sum(1 for row in rows if row["status"] == "mismatch"),
            "error": sum(1 for row in rows if row["status"] == "error"),
        },
        "repositories": rows,
    }
    args.out_dir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    path = args.out_dir / f"github-bundles-{stamp}.json"
    path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    (args.out_dir / "github-bundles-latest.json").write_text(
        json.dumps(report, indent=2) + "\n", encoding="utf-8"
    )
    print(
        f"github: {report['summary']['ok']}/{len(rows)} ok, "
        f"{report['summary']['mismatch']} mismatch, {failures} total problems"
    )
    print(f"report: {path}")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
