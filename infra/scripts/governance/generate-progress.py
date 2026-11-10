#!/usr/bin/env python3
"""Build the progress artifact for the live inventory and retired repositories."""
from __future__ import annotations

import argparse
import json
import subprocess
from datetime import datetime, timezone
from pathlib import Path

DEFAULT_ORDER = Path(
    "/home/user/repos/gardusi-gustavo/contract-json/governance/bundle-order.json"
)
DEFAULT_INVENTORY = Path(
    "/home/user/repos/gardusi-gustavo/contract-json/governance/repos.json"
)
DEFAULT_ROOT = Path("/srv/backup/git-bundles")
DEFAULT_RECON = Path("/srv/backup/reconciliation/github-bundles-latest.json")
DEFAULT_ARCHIVE = Path("/srv/backup/reconciliation/gitea-archive-latest.json")
DEFAULT_GH_META = Path("/srv/backup/github-metadata/index.json")
DEFAULT_GT_META = Path("/srv/backup/gitea-metadata/index.json")
DEFAULT_RETIRED = Path("/srv/backup/git-bundles-retired/retired-index.json")
DEFAULT_REPO_ROOT = Path("/home/user/repos/gardusi-gustavo")
DEFAULT_STATUS = Path("/srv/backup/status")
DEFAULT_OUT = Path(
    "/home/user/repos/gardusi-gustavo/database-devops/data/progress"
)


def load(path: Path, default: dict | None = None) -> dict:
    if path.is_file():
        return json.loads(path.read_text(encoding="utf-8"))
    return default or {}


def utc_now() -> str:
    return (
        datetime.now(timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z")
    )


def max_exported(index: dict) -> str | None:
    values = [row.get("exported_at") for row in index.get("repositories", [])]
    values = [value for value in values if value]
    return max(values) if values else None


def task_count(repo_root: Path, name: str) -> int:
    path = repo_root / name / "docs" / "issues"
    if not path.is_dir():
        return 0
    return len(
        [
            item
            for item in path.glob("*.json")
            if item.name not in ("schema.json", "template.json")
        ]
    )


def issue_count(full: str) -> int:
    result = subprocess.run(
        [
            "gh",
            "issue",
            "list",
            "--repo",
            full,
            "--label",
            "task",
            "--state",
            "all",
            "--json",
            "number",
            "--jq",
            "length",
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        return 0
    try:
        return int(result.stdout.strip() or 0)
    except ValueError:
        return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--order", type=Path, default=DEFAULT_ORDER)
    parser.add_argument("--inventory", type=Path, default=DEFAULT_INVENTORY)
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT)
    parser.add_argument("--reconciliation", type=Path, default=DEFAULT_RECON)
    parser.add_argument("--archive", type=Path, default=DEFAULT_ARCHIVE)
    parser.add_argument("--github-metadata", type=Path, default=DEFAULT_GH_META)
    parser.add_argument("--gitea-metadata", type=Path, default=DEFAULT_GT_META)
    parser.add_argument("--retired-index", type=Path, default=DEFAULT_RETIRED)
    parser.add_argument("--repo-root", type=Path, default=DEFAULT_REPO_ROOT)
    parser.add_argument("--status-dir", type=Path, default=DEFAULT_STATUS)
    parser.add_argument("--out-dir", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--date", default=datetime.now(timezone.utc).date().isoformat())
    parser.add_argument("--skip-issues", action="store_true")
    args = parser.parse_args()

    order = load(args.order)
    inventory = load(args.inventory)
    recon = load(args.reconciliation)
    archive = load(args.archive)
    gh_meta = load(args.github_metadata)
    gt_meta = load(args.gitea_metadata)
    retired_index = load(args.retired_index, {"repositories": []})
    bundles = load(args.root / "index.json", {"repositories": []})

    bundle_by_repo = {row["repository"]: row for row in bundles.get("repositories", [])}
    recon_by_repo = {
        row["repository"]: row for row in recon.get("repositories", [])
    }
    archive_by_repo = {
        row["repository"]: row for row in archive.get("repositories", [])
    }
    gh_meta_repos = {
        row.get("repository") for row in gh_meta.get("repositories", [])
    }
    gt_meta_repos = {
        row.get("repository") for row in gt_meta.get("repositories", [])
    }
    inventory_by_full = {
        row.get("github"): row
        for row in inventory.get("repos", [])
        if row.get("github")
    }

    rows = []
    for tier in order.get("tiers", []):
        for full in tier.get("repos", []):
            name = full.split("/", 1)[1]
            inv = inventory_by_full.get(full, {})
            archive_repo = inv.get("gitea_archive")
            if not archive_repo:
                for candidate in (full, f"gardusi-gustavo/{name}", f"human/{name}"):
                    if candidate in archive_by_repo:
                        archive_repo = candidate
                        break
            archived = archive_repo in archive_by_repo
            rec = recon_by_repo.get(full, {})
            status_file = args.status_dir / f"restore-gardusi-gustavo__{name}.json"
            rows.append(
                {
                    "repo": name,
                    "full_name": full,
                    "section": tier.get("name"),
                    "github": True,
                    "gitea": archived,
                    "gitea_archive_repo": archive_repo if archived else None,
                    "gitea_archived": archived,
                    "gitea_soak_until": archive.get("soak_until") if archived else None,
                    "bundle": full in bundle_by_repo,
                    "restore": "pass" if status_file.is_file() else "pending",
                    "reconciled": rec.get("status") == "ok",
                    "github_head": rec.get("github_head"),
                    "bundle_head": rec.get("bundle_head"),
                    "ruleset": name == "contract-json",
                    "tasks": task_count(args.repo_root, name),
                    "issues_imported": 0 if args.skip_issues else issue_count(full),
                    "issues_backup": True,
                    "github_metadata": full in gh_meta_repos,
                    "gitea_metadata": (
                        archive_repo in gt_meta_repos if archive_repo else False
                    ),
                }
            )

    retired = []
    for item in retired_index.get("repositories", []):
        retired.append(
            {
                "repo": item.get("repository"),
                "head": item.get("head"),
                "snapshots": item.get("snapshots", 0),
                "tags": item.get("tags", 0),
                "total_bytes": item.get("total_bytes", 0),
                "manifest": item.get("manifest"),
                "retirement": item.get("retirement"),
            }
        )

    data = {
        "schema": 1,
        "domain": "progress",
        "date": args.date,
        "generated_at": utc_now(),
        "metrics": [
            {"label": "Repositories", "value": len(rows)},
            {"label": "GitHub repos", "value": sum(1 for row in rows if row["github"])},
            {"label": "Gitea archived", "value": sum(1 for row in rows if row["gitea_archived"])},
            {"label": "Bundles", "value": sum(1 for row in rows if row["bundle"])},
            {"label": "Restores", "value": sum(1 for row in rows if row["restore"] == "pass")},
            {"label": "Reconciled", "value": sum(1 for row in rows if row["reconciled"])},
            {"label": "Retired", "value": len(retired)},
            {"label": "Rulesets", "value": sum(1 for row in rows if row["ruleset"])},
            {"label": "Issues imported", "value": sum(row["issues_imported"] for row in rows)},
            {"label": "GitHub metadata", "value": sum(1 for row in rows if row["github_metadata"])},
            {"label": "Gitea metadata", "value": sum(1 for row in rows if row["gitea_metadata"])},
        ],
        "gitea_archive": {
            "mode": "archive",
            "soak_until": archive.get("soak_until"),
            "report": str(args.archive),
            "archived": sum(1 for row in rows if row["gitea_archived"]),
            "total": len(archive.get("repositories", [])),
        },
        "reconciliation": {
            "generated_at": recon.get("generated_at"),
            "report": str(args.reconciliation),
            "summary": recon.get("summary", {}),
        },
        "metadata": {
            "github_index": str(args.github_metadata),
            "gitea_index": str(args.gitea_metadata),
            "github_exported_at": max_exported(gh_meta),
            "gitea_exported_at": max_exported(gt_meta),
        },
        "repositories": rows,
        "retired": retired,
    }

    args.out_dir.mkdir(parents=True, exist_ok=True)
    path = args.out_dir / f"{args.date}.json"
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    print(
        f"progress: {path} "
        f"repos={len(rows)} reconciled={sum(1 for r in rows if r['reconciled'])} "
        f"archived={sum(1 for r in rows if r['gitea_archived'])} retired={len(retired)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
