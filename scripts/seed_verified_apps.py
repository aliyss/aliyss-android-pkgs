#!/usr/bin/env python3
"""Seed apps from the privacyguides/verified-apps signing-certificate database.

https://github.com/privacyguides/verified-apps publishes ``data.yml``: a
public database of Android package IDs with their signing-certificate
fingerprints (SHA-256) and, for some entries, the SHA-256 of specific APK
files per source (F-Droid / Google Play / ...).

Signing-certificate fingerprints are version-independent, so they are the
correct seed data for this repository: they identify the *legitimate* signer
of every package, which scripts/update.py can later confirm on each download.

For each package this script writes::

    pkgs/<category>/<package.id>/
        package.nix     static template reading ./hashes.json
        hashes.json     {"version": "", "architectures": {}}  (pin me via update.py)
        verified.json   signer fingerprints + attribution

Usage::

    python scripts/seed_verified_apps.py                 # fetch data.yml and seed
    python scripts/seed_verified_apps.py --from-file data.yml
    python scripts/seed_verified_apps.py --dry-run       # only print the plan
    python scripts/seed_verified_apps.py --limit 30      # cap the number of apps
    python scripts/seed_verified_apps.py --only chat.simplex.app

The data.yml is licensed under CC-BY-4.0; attribution is embedded in every
generated verified.json.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import httpx
import yaml

log = None  # placeholder to keep linters happy; we print directly

REPO_ROOT = Path(__file__).resolve().parent.parent
PKGS_DIR = REPO_ROOT / "pkgs"

VERIFIED_APPS_URL = "https://raw.githubusercontent.com/privacyguides/verified-apps/main/data.yml"
DATASET = "privacyguides/verified-apps"
DATASET_LICENSE = "CC-BY-4.0"
DATASET_LICENSE_URL = "https://github.com/privacyguides/verified-apps/blob/main/LICENSE.txt"

from categories import derive_pname, guess_category  # noqa: F401 (re-exported for callers)


def load_data(source: str | Path) -> dict:
    text = httpx.get(VERIFIED_APPS_URL, timeout=30, follow_redirects=True).text if source == "network" else Path(source).read_text()
    return yaml.safe_load(text)


def render_package(package: str, pname: str) -> str:
    return f"""{'{ fetchApk }:'}

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {{
  pname = "{pname}";
  appId = "{package}";
  version = pin.version;
  archs = pin.architectures;
}}
"""


def render_pin() -> str:
    return json.dumps({"version": "", "architectures": {}}, indent=2) + "\n"


def render_verified(package: str, fingerprints: list[str]) -> str:
    return json.dumps({
        "package": package,
        "signerFingerprints": fingerprints,
        "source": DATASET,
        "source-license": DATASET_LICENSE,
        "source-license-url": DATASET_LICENSE_URL,
    }, indent=2) + "\n"


def main(cli: argparse.Namespace) -> None:
    data = load_data(cli.file or "network")
    if data.get("schema", 0) < 1 or not isinstance(data.get("packages"), list):
        print(f"unexpected data.yml schema: {data.get('schema')}")
        sys.exit(1)

    existing = {p.parent.name for p in PKGS_DIR.rglob("package.nix")}
    planned = []
    for entry in data["packages"]:
        package = entry.get("package")
        fingerprints = set()
        for sig in entry.get("signature", []):
            fp = " ".join(sig.get("fingerprint", "").split())  # collapse multiline
            if fp:
                fingerprints.add(fp)
        fingerprints = sorted(fingerprints)
        if not package or package in existing or package in [p[0] for p in planned]:
            continue
        if cli.only and package != cli.only:
            continue
        planned.append((package, fingerprints))

    if cli.limit:
        planned = planned[: cli.limit]

    if cli.dry_run or not planned:
        print(f"{'[dry] would add:' if cli.dry_run else 'nothing to add'}")
        for package, fp in planned:
            cat = guess_category(package)
            print(f"  {cat}/{package}  fingerprints={len(fp)}")
        if not planned:
            sys.exit(0)
        if cli.dry_run:
            sys.exit(0)

    created = 0
    for package, fingerprints in planned:
        app_dir = PKGS_DIR / guess_category(package) / package
        app_dir.mkdir(parents=True, exist_ok=True)
        (app_dir / "package.nix").write_text(render_package(package, derive_pname(package)))
        (app_dir / "hashes.json").write_text(render_pin())
        (app_dir / "verified.json").write_text(render_verified(package, fingerprints))
        created += 1
        print(f"[+] {app_dir.relative_to(PKGS_DIR.parent)}  fingerprints={len(fingerprints)}")

    print(f"seeded {created} apps. Next: run scripts/update.py to pin versions + hashes.")


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Seed apps from privacyguides/verified-apps")
    p.add_argument("--from-file", dest="file", metavar="PATH", help="use a local copy of data.yml instead of downloading")
    p.add_argument("--dry-run", action="store_true", help="print the plan, write nothing")
    p.add_argument("--limit", type=int, help="cap the number of apps seeded")
    p.add_argument("--only", metavar="APP_ID", help="seed a single package")
    return p.parse_args()


if __name__ == "__main__":
    main(parse_args())