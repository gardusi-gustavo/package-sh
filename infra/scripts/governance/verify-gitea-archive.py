#!/usr/bin/env python3
"""Verify the frozen Gitea archive against its recorded heads."""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

DEFAULT_ENV = Path("/home/user/.config/gitea/env")
DEFAULT_REPORT = Path("/srv/backup/reconciliation/gitea-archive-latest.json")
DEFAULT_OUT = Path("/srv/backup/reconciliation")


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


def get(base: str, token: str, path: str):
    request = urllib.request.Request(
        f"{base.rstrip('/')}/api/v1{path}",
        headers={"Authorization": f"token {token}", "Accept": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        body = response.read().decode()
    return json.loads(body) if body.strip() else None


def now() -> str:
    return (
        datetime.now(timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z")
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--env", type=Path, default=DEFAULT_ENV)
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    parser.add_argument("--out-dir", type=Path, default=DEFAULT_OUT)
    args = parser.parse_args()

    env = load_env(args.env)
    base = env.get("GITEA_URL", "")
    token = env.get("GITEA_TOKEN", "")
    if not base or not token:
        print("error: GITEA_URL and GITEA_TOKEN are required", file=sys.stderr)
        return 2
    if not args.report.is_file():
        print(f"error: archive report missing: {args.report}", file=sys.stderr)
        return 2
    archive = json.loads(args.report.read_text(encoding="utf-8"))

    rows = []
    failures = 0
    for item in archive.get("repositories", []):
        repo = item["repository"]
        row = {"repository": repo, "expected_head": item.get("head"), "status": "ok"}
        try:
            current = get(base, token, f"/repos/{repo}")
            if not current.get("archived"):
                row["errors"] = ["not archived"]
            commits = get(base, token, f"/repos/{repo}/commits?limit=1")
            row["actual_head"] = commits[0]["sha"] if commits else None
            if row["expected_head"] and row["actual_head"] != row["expected_head"]:
                row.setdefault("errors", []).append("head drift")
        except Exception as exc:  # noqa: BLE001
            row["errors"] = [str(exc)]
        if row.get("errors"):
            row["status"] = "error"
            failures += 1
        rows.append(row)

    report = {
        "schema": 1,
        "kind": "gitea-archive-verification",
        "generated_at": now(),
        "archive_report": str(args.report),
        "summary": {
            "repositories": len(rows),
            "ok": sum(1 for row in rows if row["status"] == "ok"),
            "error": failures,
        },
        "repositories": rows,
    }
    args.out_dir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    path = args.out_dir / f"gitea-archive-verify-{stamp}.json"
    path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    (args.out_dir / "gitea-archive-verify-latest.json").write_text(
        json.dumps(report, indent=2) + "\n", encoding="utf-8"
    )
    print(f"archive: {report['summary']['ok']}/{len(rows)} ok, {failures} error")
    print(f"report: {path}")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
