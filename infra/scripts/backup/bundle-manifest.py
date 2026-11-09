#!/usr/bin/env python3
"""Write per-repository bundle manifests, checksums, and the global index."""
from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
from datetime import datetime, timezone
from pathlib import Path


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def iso_mtime(path: Path) -> str:
    return datetime.fromtimestamp(path.stat().st_mtime, timezone.utc).replace(
        microsecond=0).isoformat().replace("+00:00", "Z")


def list_heads(path: Path) -> dict[str, str]:
    if path.name.endswith(".gpg"):
        return {}
    out = subprocess.run(
        ["git", "bundle", "list-heads", str(path)],
        check=True, capture_output=True, text=True,
    ).stdout
    refs: dict[str, str] = {}
    for line in out.splitlines():
        parts = line.split(maxsplit=1)
        if len(parts) == 2:
            refs[parts[1].strip()] = parts[0]
    return refs


def bundle_entry(repo_dir: Path, path: Path, kind: str) -> dict:
    rel = path.relative_to(repo_dir).as_posix()
    refs = list_heads(path)
    entry = {
        "kind": kind,
        "path": rel,
        "sha256": sha256(path),
        "size_bytes": path.stat().st_size,
        "created_at": iso_mtime(path),
        "encrypted": path.name.endswith(".gpg"),
    }
    if refs:
        entry["refs"] = refs
    if kind == "tag":
        tag_refs = [ref for ref in refs if ref.startswith("refs/tags/")]
        if tag_refs:
            entry["tag"] = tag_refs[0].removeprefix("refs/tags/")
            entry["commit"] = refs[tag_refs[0]]
        else:
            stem = path.name.removesuffix(".bundle.gpg").removesuffix(".bundle")
            if "-" in stem:
                tag, _, commit = stem.rpartition("-")
                entry["tag"] = tag
                entry["commit"] = commit
    return entry


def write_atomic(path: Path, text: str) -> None:
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    tmp.replace(path)


def write_repo_manifest(root: Path, repo: str) -> Path:
    repo_dir = root / repo
    snapshot_dir = repo_dir / "snapshots"
    tag_dir = repo_dir / "tags"
    bundles: list[dict] = []
    for path in sorted(snapshot_dir.glob("*.bundle")) + sorted(snapshot_dir.glob("*.bundle.gpg")):
        bundles.append(bundle_entry(repo_dir, path, "snapshot"))
    for path in sorted(tag_dir.glob("*.bundle")) + sorted(tag_dir.glob("*.bundle.gpg")):
        bundles.append(bundle_entry(repo_dir, path, "tag"))

    snapshots = [item for item in bundles if item["kind"] == "snapshot"]
    latest = snapshots[-1] if snapshots else None
    refs = latest.get("refs", {}) if latest else {}
    head = refs.get("refs/heads/main") or (next(iter(refs.values())) if refs else None)
    manifest = {
        "schema": 1,
        "repository": repo,
        "generated_at": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "head": head,
        "refs": sorted(refs),
        "latest_snapshot": latest["path"] if latest else None,
        "bundles": bundles,
    }
    write_atomic(repo_dir / "manifest.json", json.dumps(manifest, indent=2) + "\n")
    checksums = "".join(f"{item['sha256']}  {item['path']}\n" for item in bundles)
    write_atomic(repo_dir / "SHA256SUMS", checksums)
    return repo_dir / "manifest.json"


def write_index(root: Path) -> Path:
    rows = []
    for manifest_path in sorted(root.glob("*/*/manifest.json")):
        data = json.loads(manifest_path.read_text(encoding="utf-8"))
        bundles = data.get("bundles", [])
        rows.append({
            "repository": data.get("repository"),
            "head": data.get("head"),
            "latest_snapshot": data.get("latest_snapshot"),
            "snapshots": sum(1 for item in bundles if item.get("kind") == "snapshot"),
            "tags": sum(1 for item in bundles if item.get("kind") == "tag"),
            "total_bytes": sum(int(item.get("size_bytes", 0)) for item in bundles),
            "manifest": manifest_path.relative_to(root).as_posix(),
        })
    index = {
        "schema": 1,
        "generated_at": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "repositories": rows,
    }
    path = root / "index.json"
    write_atomic(path, json.dumps(index, indent=2) + "\n")
    return path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    parser.add_argument("--repo", required=True)
    args = parser.parse_args()
    root = Path(args.root).resolve()
    repo = args.repo.strip("/")
    manifest = write_repo_manifest(root, repo)
    index = write_index(root)
    print(f"manifest: {manifest}")
    print(f"index: {index}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
