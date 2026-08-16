#!/usr/bin/env python3
"""Re-categorize apps using the curated F-Droid / IzzyOnDroid category taxonomy.

``index-v2.json`` (published by f-droid.org and IzzyOnDroid) carries, per app,
categories curated by the repo maintainers plus a human-readable name and
summary. This script uses those categories to move apps that ended up in
``pkgs/misc/`` into the proper top-level category, falling back to keyword
heuristics (``categories.guess_category``) when a repo does not list a usable
category for an app.

Usage::

    python scripts/recategorize.py                 # move misc/ apps (F-Droid + Izzy metadata)
    python scripts/recategorize.py --repo fdroid   # only consult the f-droid.org index
    python scripts/recategorize.py --repo izzy     # only IzzyOnDroid
    python scripts/recategorize.py --dry-run       # print the plan, move nothing
    python scripts/recategorize.py --all           # reconsider every app dir, not just misc/
    python scripts/recategorize.py --from-file index-v2.json   # offline

Run it again after seeding: it skips apps that are already in a category the
metadata agrees with, so it is idempotent.
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from pathlib import Path
from typing import Any, cast

import httpx

from categories import category_from_index, guess_category

# JSON payloads from index-v2.json are untyped by nature.
Json = dict[str, Any]

REPO_ROOT = Path(__file__).resolve().parent.parent
PKGS_DIR = REPO_ROOT / "pkgs"

DEFAULT_REPO = "https://f-droid.org/repo"

REPO_ALIASES = {
    "fdroid": "https://f-droid.org/repo",
    "f-droid": "https://f-droid.org/repo",
    "f-droid.org": "https://f-droid.org/repo",
    "izzy": "https://apt.izzysoft.de/fdroid/repo",
    "izzyondroid": "https://apt.izzysoft.de/fdroid/repo",
    "izzysoft": "https://apt.izzysoft.de/fdroid/repo",
    "all": "all",
}

TIMEOUT = httpx.Timeout(120.0)
HEADERS = {"User-Agent": "android-repo-recategorizer/1.0 (+https://github.com/)"}


def load_v2(source: str | Path, repo_url: str) -> Json:
    if source == "network":
        url = f"{repo_url.rstrip('/')}/index-v2.json"
        with httpx.Client(headers=HEADERS, timeout=TIMEOUT, follow_redirects=True) as client:
            resp = client.get(url)
            resp.raise_for_status()
            return cast(Json, resp.json())
    return cast(Json, json.loads(Path(source).read_text()))


def _localized(value: Any) -> str:
    """index-v2 name/summary are localized maps ({'en-US': ...}); flatten them."""
    if isinstance(value, dict):
        return str(value.get("en-US") or next(iter(value.values()), ""))
    return str(value or "")


def metadata_map(data: Json) -> dict[str, dict[str, Any]]:
    """Extract {categories, summary, name} per package from an index-v2 doc."""
    out: dict[str, dict[str, Any]] = {}
    for pkg, entry in cast(Json, data.get("packages") or {}).items():
        meta = cast(Json, entry.get("metadata") or {})
        out[pkg] = {
            "categories": list(meta.get("categories") or []),
            "summary": _localized(meta.get("summary")),
            "name": _localized(meta.get("name")),
        }
    return out


def plan_moves(
    pkgs_dir: Path, metadata: dict[str, dict[str, Any]], all_categories: bool
) -> list[tuple[str, str, str]]:
    """Return (current_category, app_id, target_category) triples for apps to move."""
    moves = []
    for category in sorted(pkgs_dir.iterdir()):
        if not category.is_dir():
            continue
        if not all_categories and category.name != "misc":
            continue
        for app_dir in sorted(category.iterdir()):
            if not app_dir.is_dir():
                continue
            app_id = app_dir.name
            info = metadata.get(app_id)
            if info:
                target = category_from_index(
                    app_id, info["categories"], info["summary"], info["name"]
                )
            else:
                target = guess_category(app_id)
            if target != category.name:
                moves.append((category.name, app_id, target))
    return moves


def main(cli: argparse.Namespace) -> None:
    repos = ["fdroid", "izzy"] if REPO_ALIASES.get(cli.repo) == "all" else [cli.repo]
    if cli.file:
        repos = [cli.repo]  # a single local index file cannot stand in for several repos

    metadata: dict[str, dict[str, Any]] = {}
    for repo in repos:
        repo_url = REPO_ALIASES.get(repo, repo).rstrip("/")
        if cli.file:
            data = load_v2(cli.file, repo_url)
        else:
            data = load_v2("network", repo_url)
        # f-droid.org is canonical: keep its metadata when an app is in both repos
        for pkg, info in metadata_map(data).items():
            metadata.setdefault(pkg, info)

    pkgs_dir = cli.pkgs_dir or PKGS_DIR
    moves = plan_moves(pkgs_dir, metadata, cli.all)
    moves.sort()

    misc_before = (
        len([d for d in (pkgs_dir / "misc").iterdir() if d.is_dir()])
        if (pkgs_dir / "misc").is_dir()
        else 0
    )
    leaving_misc = sum(1 for c, _, _ in moves if c == "misc")
    entering_misc = sum(1 for _, _, t in moves if t == "misc")
    per_target = Counter(target for _, _, target in moves)
    print(
        f"plan: move {len(moves)} app(s); misc {misc_before} -> {misc_before - leaving_misc + entering_misc}"
    )
    for target, n in sorted(per_target.items()):
        print(f"  -> {target}: {n}")

    if cli.dry_run or not moves:
        if cli.dry_run:
            for old, app_id, new in moves:
                print(f"  [dry] {old}/{app_id} -> {new}")
        sys.exit(0)

    moved = 0
    for old, app_id, new in moves:
        src = pkgs_dir / old / app_id
        dst = pkgs_dir / new / app_id
        if not src.is_dir():
            print(f"[!] {old}/{app_id} missing, skipping")
            continue
        dst.parent.mkdir(parents=True, exist_ok=True)
        src.rename(dst)
        moved += 1
        print(f"[move] {old}/{app_id} -> {new}")

    remaining = (
        len([d for d in (pkgs_dir / "misc").iterdir() if d.is_dir()])
        if (pkgs_dir / "misc").is_dir()
        else 0
    )
    print(f"moved {moved} apps. misc/ now holds {remaining} apps. Run `nix flake check` to verify.")


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Re-categorize apps from curated index categories")
    p.add_argument(
        "--repo",
        default="all",
        choices=sorted(REPO_ALIASES),
        help="which index(es) to consult: fdroid | izzy | all (default: all)",
    )
    p.add_argument(
        "--from-file",
        dest="file",
        metavar="PATH",
        help="use a local index-v2.json instead of downloading",
    )
    p.add_argument("--dry-run", action="store_true", help="print the plan, move nothing")
    p.add_argument("--all", action="store_true", help="reconsider every app dir, not only misc/")
    p.add_argument(
        "--pkgs-dir",
        type=Path,
        default=PKGS_DIR,
        help="where the pkgs tree lives (default: ./pkgs)",
    )
    return p.parse_args()


if __name__ == "__main__":
    main(parse_args())
