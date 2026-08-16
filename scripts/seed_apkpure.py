#!/usr/bin/env python3
"""Seed apps from APKPure (source = "apk-pure") into the package tree.

APKPure publishes no signed index, so unlike seed_fdroid.py there is no
offline pin: this script only scaffolds the app directory — a ``package.nix``
with the default ``apk-pure`` source (fetchApk defaults), an *empty*
``hashes.json``, an empty ``history.json`` and a ``verified.json`` carrying
attribution (fingerprints are recorded by update.py after the first verified
download) — and ``scripts/update.py`` then downloads the latest APK and pins
version + hashes:

    python scripts/seed_apkpure.py com.spotify.music
    python scripts/seed_apkpure.py --from-file apps.txt
    python scripts/update.py --only com.spotify.music
    python scripts/update.py --history --only com.spotify.music   # fetch version history

Apps that APKPure does not carry simply stay unpinned (update.py reports the
failure); this script itself never touches the network. Use the same
category/pname helpers as the other seeders so everything stays consistent.

Usage:
    python scripts/seed_apkpure.py <app-id> [<app-id> ...]
    python scripts/seed_apkpure.py --from-file <path>
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import seed_verified_apps as sva

REPO_ROOT = Path(__file__).resolve().parent.parent
PKGS_DIR = REPO_ROOT / "pkgs"

APKPURE_HOMEPAGE = "https://apkpure.com"


def existing_apps() -> set[str]:
    return {p.parent.name for p in PKGS_DIR.rglob("package.nix")}


def render_verified(package: str, source: str = "apk-pure") -> str:
    """Attribution-only verified.json: no public signer database.

    ``signerFingerprints`` stays empty until scripts/update.py verifies the
    first downloaded APK with apksigner and records the observed fingerprints.
    ``source`` is a fetchApk source name ("apk-pure", "github-releases", ...)
    and controls the attribution text.
    """
    source_label = {
        "apk-pure": "APKPure (no public signing-certificate database; ",
        "github-releases": "GitHub releases (no public signing-certificate database; ",
    }.get(source, f"{source} (no public signing-certificate database; ")
    return (
        json.dumps(
            {
                "package": package,
                "signerFingerprints": [],
                "source": source_label
                + "fingerprints recorded by scripts/update.py after the first "
                "verified download)",
                "source-url": APKPURE_HOMEPAGE,
            },
            indent=2,
        )
        + "\n"
    )


def render_history() -> str:
    """Empty version-history lockfile; populated by `update.py --history`."""
    return json.dumps({"versions": []}, indent=2) + "\n"


def seed_one(package: str, existing: set[str]) -> str | None:
    if package in existing:
        return None
    app_dir = PKGS_DIR / sva.guess_category(package) / package
    app_dir.mkdir(parents=True, exist_ok=True)
    (app_dir / "package.nix").write_text(sva.render_package(package, sva.derive_pname(package)))
    (app_dir / "hashes.json").write_text(sva.render_pin())
    (app_dir / "verified.json").write_text(render_verified(package))
    (app_dir / "history.json").write_text(render_history())
    return str(app_dir.relative_to(PKGS_DIR.parent))


def fill_one(app_dir: Path) -> list[str]:
    """Add sidecar files (verified.json, history.json) to an existing app dir.

    Used to heal apps seeded before those files existed: never touches
    package.nix / hashes.json. Returns the paths written.
    """
    written = []
    package = app_dir.name
    if not (app_dir / "verified.json").exists():
        (app_dir / "verified.json").write_text(render_verified(package))
        written.append("verified.json")
    if not (app_dir / "history.json").exists():
        (app_dir / "history.json").write_text(render_history())
        written.append("history.json")
    return written


def main(cli: argparse.Namespace) -> None:
    ids = list(cli.app_ids)
    if cli.file:
        ids += Path(cli.file).read_text().split()
    ids = sorted(set(ids))
    existing = existing_apps()

    if cli.fill:
        # Heal sidecars on apps already present in the tree (apk-pure only).
        filled = []
        unchanged = 0
        for app_dir in sorted(PKGS_DIR.rglob("package.nix")):
            parent = app_dir.parent
            text = app_dir.read_text()
            if 'source = "f-droid"' in text or 'source = "google-play"' in text:
                continue  # f-droid / play apps have their own verified.json flow
            written = fill_one(parent)
            if written:
                filled.append(f"{parent.relative_to(PKGS_DIR.parent)}: {'+'.join(written)}")
            else:
                unchanged += 1
        for line in filled:
            print(f"[+] {line}")
        print(f"filled sidecars on {len(filled)} apps ({unchanged} already complete).")
        return

    created = []
    skipped = []
    for package in ids:
        rel = seed_one(package, existing)
        if rel:
            created.append(rel)
            existing.add(package)
        else:
            skipped.append(package)

    for rel in created:
        print(f"[+] {rel}")
    if skipped:
        print(f"(skipped {len(skipped)} already present: {', '.join(skipped)})")
    print(
        f"seeded {len(created)} apps (empty pins). Next: run "
        "`python scripts/update.py --only <app-id>` per app to pin the latest APK."
    )
    if not created:
        sys.exit(0)


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Scaffold apk-pure app dirs (empty pins) for scripts/update.py to pin"
    )
    p.add_argument(
        "app_ids", nargs="*", metavar="APP_ID", help="app ids to seed (e.g. com.spotify.music)"
    )
    p.add_argument(
        "--from-file", dest="file", metavar="PATH", help="read app ids (one per line) from a file"
    )
    p.add_argument(
        "--fill",
        action="store_true",
        help="add missing verified.json / history.json to existing apk-pure apps",
    )
    p.add_argument(
        "--pkgs-dir", type=Path, default=PKGS_DIR, help="where to write apps (default: ./pkgs)"
    )
    return p.parse_args()


if __name__ == "__main__":
    main(parse_args())
