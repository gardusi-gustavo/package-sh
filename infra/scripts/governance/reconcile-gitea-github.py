#!/usr/bin/env python3
"""Reconcile GitHub, Gitea, and local Git bundle state.

For every repository in the canonical topological order, compare:

  * GitHub ``main`` commit
  * Gitea ``main`` commit (mapped for the private vault)
  * latest local bundle snapshot head
  * GitHub tags against immutable tag bundles

Exit non-zero if any head or tag differs, or if a bundle cannot be read.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

DEFAULT_ORDER = Path(
    "/home/user/repos/gardusi-gustavo/contract-json/governance/bundle-order.json"
)
DEFAULT_ROOT = Path("/srv/backup/git-bundles")
DEFAULT_REPORT_DIR = Path("/srv/backup/reconciliation")
DEFAULT_ENV = Path("/home/user/.config/gitea/env")
PASSFILE = Path("/srv/backup/secrets/backup.pass")

GITEA_SKIP = {"gardusi-gustavo/gardusi-gustavo", "gardusi-gustavo/.github"}
GITEA_MAP = {"gardusi-gustavo/private": "human/private"}


def utc_now() -> str:
    return (
        datetime.now(timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z")
    )


def load_env(path: Path) -> dict[str, str]:
    env = dict(os.environ)
    if path.is_file():
        for line in path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            env.setdefault(key, value)
    return env


def run(cmd: list[str], *, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, check=check)


def gh_json(path: str):
    result = run(["gh", "api", path])
    text = result.stdout.strip()
    return json.loads(text) if text else None


def gh_list(path: str) -> list:
    result = run(["gh", "api", "--paginate", path, "--jq", ".[]"])
    return [json.loads(line) for line in result.stdout.splitlines() if line.strip()]


def gitea_json(base: str, token: str, path: str):
    request = urllib.request.Request(
        f"{base.rstrip('/')}/api/v1{path}",
        headers={"Authorization": f"token {token}", "Accept": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        data = response.read().decode()
    return json.loads(data) if data.strip() else None


def list_heads(bundle: Path) -> dict[str, str]:
    result = run(["git", "bundle", "list-heads", str(bundle)], check=False)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or f"cannot read {bundle}")
    refs: dict[str, str] = {}
    for line in result.stdout.splitlines():
        parts = line.split(maxsplit=1)
        if len(parts) == 2:
            refs[parts[1].strip()] = parts[0]
    return refs


def bundle_heads(bundle: Path) -> dict[str, str]:
    if not bundle.name.endswith(".gpg"):
        return list_heads(bundle)
    if not PASSFILE.is_file():
        raise RuntimeError(f"encrypted bundle without passphrase file: {bundle}")
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


def manifest_for(root: Path, repo: str) -> dict:
    path = root / repo / "manifest.json"
    if not path.is_file():
        raise RuntimeError(f"missing manifest: {path}")
    return json.loads(path.read_text(encoding="utf-8"))


def bundle_state(root: Path, repo: str) -> dict:
    manifest = manifest_for(root, repo)
    latest = manifest.get("latest_snapshot")
    if not latest:
        raise RuntimeError("manifest has no snapshot")
    snapshot = root / repo / latest
    if not snapshot.is_file():
        raise RuntimeError(f"missing snapshot: {snapshot}")
    refs = bundle_heads(snapshot)
    head = refs.get("refs/heads/main") or refs.get("HEAD")
    if not head:
        heads = sorted(set(refs.values()))
        if len(heads) != 1:
            raise RuntimeError(f"ambiguous snapshot head: {sorted(refs)}")
        head = heads[0]
    tags = sorted(
        {
            entry["tag"]
            for entry in manifest.get("bundles", [])
            if entry.get("kind") == "tag" and entry.get("tag")
        }
    )
    return {"head": head, "latest_snapshot": latest, "tags": tags, "refs": refs}


def github_state(repo: str) -> dict:
    commit = gh_json(f"repos/{repo}/commits/main")
    if not commit:
        raise RuntimeError("GitHub returned no commit")
    tags = sorted({item["name"] for item in gh_list(f"repos/{repo}/tags")})
    return {"head": commit["sha"], "tree": commit["commit"]["tree"]["sha"], "tags": tags}


def gitea_state(base: str, token: str, repo: str) -> dict:
    commits = gitea_json(base, token, f"/repos/{repo}/commits?limit=1")
    if not commits:
        raise RuntimeError("Gitea returned no commit")
    return {"head": commits[0]["sha"]}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--order", type=Path, default=DEFAULT_ORDER)
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT)
    parser.add_argument("--report-dir", type=Path, default=DEFAULT_REPORT_DIR)
    parser.add_argument("--env", type=Path, default=DEFAULT_ENV)
    parser.add_argument("--json", action="store_true", help="print the report only")
    args = parser.parse_args()

    env = load_env(args.env)
    gitea_base = env.get("GITEA_URL", "")
    gitea_token = env.get("GITEA_TOKEN", "")
    if not gitea_base or not gitea_token:
        print("error: GITEA_URL and GITEA_TOKEN are required", file=sys.stderr)
        return 2

    order = json.loads(args.order.read_text(encoding="utf-8"))
    repos = [repo for tier in order["tiers"] for repo in tier["repos"]]
    rows: list[dict] = []
    failures = 0

    for repo in repos:
        row: dict = {"repository": repo, "status": "ok", "errors": []}
        try:
            gh = github_state(repo)
            bundle = bundle_state(args.root, repo)
            row["github_head"] = gh["head"]
            row["bundle_head"] = bundle["head"]
            row["latest_snapshot"] = bundle["latest_snapshot"]
            row["github_tree"] = gh["tree"]
            row["tree_check"] = "implied-by-sha"
            if gh["head"] != bundle["head"]:
                row["errors"].append("github-head != bundle-head")

            if repo in GITEA_SKIP:
                row["gitea_head"] = None
                row["gitea_repo"] = None
            else:
                gitea_repo = GITEA_MAP.get(repo, repo)
                gt = gitea_state(gitea_base, gitea_token, gitea_repo)
                row["gitea_repo"] = gitea_repo
                row["gitea_head"] = gt["head"]
                if gh["head"] != gt["head"]:
                    row["errors"].append("github-head != gitea-head")

            missing_tags = sorted(set(gh["tags"]) - set(bundle["tags"]))
            row["github_tags"] = len(gh["tags"])
            row["bundle_tags"] = len(bundle["tags"])
            row["missing_tag_bundles"] = missing_tags
            if missing_tags:
                row["errors"].append("missing tag bundles")
        except Exception as exc:  # noqa: BLE001 - report every repository
            row["status"] = "error"
            row["errors"].append(str(exc))
        if row["errors"]:
            row["status"] = "mismatch" if row["status"] == "ok" else row["status"]
            failures += 1
        rows.append(row)

    report = {
        "schema": 1,
        "generated_at": utc_now(),
        "order": str(args.order),
        "bundle_root": str(args.root),
        "gitea_url": gitea_base,
        "summary": {
            "repositories": len(rows),
            "ok": sum(1 for row in rows if row["status"] == "ok"),
            "mismatch": sum(1 for row in rows if row["status"] == "mismatch"),
            "error": sum(1 for row in rows if row["status"] == "error"),
        },
        "repositories": rows,
    }

    args.report_dir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    report_path = args.report_dir / f"{stamp}.json"
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    (args.report_dir / "latest.json").write_text(
        json.dumps(report, indent=2) + "\n", encoding="utf-8"
    )

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(
            f"{'repository':26} {'github':9} {'gitea':9} {'bundle':9} "
            f"{'tags':11} status"
        )
        for row in rows:
            missing = len(row.get("missing_tag_bundles", []))
            print(
                f"{row['repository']:26} "
                f"{(row.get('github_head') or '-')[:8]:9} "
                f"{(row.get('gitea_head') or 'n/a')[:8]:9} "
                f"{(row.get('bundle_head') or '-')[:8]:9} "
                f"{row.get('github_tags', 0):>3}/{row.get('bundle_tags', 0):<3}"
                f"{('-' + str(missing)) if missing else '':4} "
                f"{row['status']}"
            )
        print(f"\nreport: {report_path}")
        print(
            "summary: "
            f"{report['summary']['ok']} ok, "
            f"{report['summary']['mismatch']} mismatch, "
            f"{report['summary']['error']} error"
        )

    return 0 if failures == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
