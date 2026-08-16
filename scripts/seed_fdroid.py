#!/usr/bin/env python3
"""Seed the repository from a F-Droid-format repository index (zero downloads).

``https://f-droid.org/repo/index-v1.json`` is the *signed* index of every
package in the f-droid.org repository. Each APK entry carries everything
needed to pin the app without downloading it:

    versionName / versionCode   human and numeric version
    apkName                     exact file name inside the repo - the download
                                URL ``<repo>/<apkName>`` is deterministic
    hash                        sha256 of the APK file itself (hashType=sha256)
    signer                      SHA-256 fingerprint of the signing certificate
    nativecode                  ABIs the APK was built for (empty = universal)

``scripts/update.py`` verifies downloads with apksigner against the signer
fingerprints, and ``lib/fetchApk.nix`` fetches ``<repo>/<apkName>`` with
``outputHashMode = "flat"`` so the index hash is the build hash. Because both
the URL and the hash come from the same signed index, seeds are trustworthy
and builds are deterministic.

For each package this script writes::

    pkgs/<category>/<package.id>/
        package.nix     template reading ./hashes.json (source = "f-droid")
        hashes.json     {"version", "apkName", "architectures": {system: {archStr, hash}}}
        verified.json   signer fingerprints + attribution

Usage::

    python scripts/seed_fdroid.py                          # f-droid.org main repo
    python scripts/seed_fdroid.py --repo izzy              # IzzyOnDroid (alias)
    python scripts/seed_fdroid.py --repo https://apt.izzysoft.de/fdroid/repo
    python scripts/seed_fdroid.py --from-file index-v1.json
    python scripts/seed_fdroid.py --dry-run
    python scripts/seed_fdroid.py --limit 500
    python scripts/seed_fdroid.py --only de.jepfa.hyle_x
    python scripts/seed_fdroid.py --all                    # include per-ABI-only APKs

Run once per repository (F-Droid first, then IzzyOnDroid): apps already present
are skipped, so the second run only adds apps the first one did not have.

Trust model: the index is served over TLS; f-droid.org additionally signs it
(JAR signature via ``index-v1.jar`` plus GPG via ``index-v1.json.asc`` - see
https://f-droid.org/en/docs/All_our_APIs/). For maximum trust, download the
index through the signed JAR and verify it before seeding; the hashes pinned
here are then covered by that signature, and `update.py` still re-verifies
each download's signer with apksigner when it is available.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any, cast

import httpx

import seed_verified_apps as sva
from update import FLAKE_SYSTEMS, sha256_hex_to_sri

# JSON payloads from the repo index are untyped by nature.
Json = dict[str, Any]

REPO_ROOT = Path(__file__).resolve().parent.parent
PKGS_DIR = REPO_ROOT / "pkgs"

DEFAULT_REPO = "https://f-droid.org/repo"

# Convenience aliases for --repo.
REPO_ALIASES = {
    "fdroid": "https://f-droid.org/repo",
    "f-droid": "https://f-droid.org/repo",
    "f-droid.org": "https://f-droid.org/repo",
    "izzy": "https://apt.izzysoft.de/fdroid/repo",
    "izzyondroid": "https://apt.izzysoft.de/fdroid/repo",
    "izzysoft": "https://apt.izzysoft.de/fdroid/repo",
}

# An APK is treated as "universal" (installable everywhere) when it declares
# no nativecode, or covers at least these four ABIs in a single file.
UNIVERSAL_ABIS = {"arm64-v8a", "armeabi-v7a", "x86", "x86_64"}

TIMEOUT = httpx.Timeout(120.0)
HEADERS = {"User-Agent": "android-repo-seeder/1.0 (+https://github.com/)"}


def is_universal(entry: Json) -> bool:
    native = set(entry.get("nativecode") or [])
    return not native or UNIVERSAL_ABIS <= native


def pick_latest(entries: list[Json]) -> Json | None:
    if not entries:
        return None
    return max(entries, key=lambda e: int(e.get("versionCode") or 0))


def hex_to_fingerprint(hexstr: str) -> str:
    hexstr = hexstr.replace(":", "").strip().lower()
    return ":".join(hexstr[i : i + 2] for i in range(0, len(hexstr), 2)).upper()


def load_index(source: str | Path, repo_url: str | None = None) -> Json:
    if source == "network":
        url = f"{(repo_url or DEFAULT_REPO).rstrip('/')}/index-v1.json"
        with httpx.Client(headers=HEADERS, timeout=TIMEOUT, follow_redirects=True) as client:
            resp = client.get(url)
            resp.raise_for_status()
            return cast(Json, resp.json())
    return cast(Json, json.loads(Path(source).read_text()))


def render_package(package: str, pname: str, repo_url: str) -> str:
    return f"""{"{ fetchApk }:"}

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {{
  pname = "{pname}";
  appId = "{package}";
  source = "f-droid";
  repoUrl = "{repo_url}";
  apkName = pin.apkName;
  version = pin.version;
  archs = pin.architectures;
}}
"""


def render_pin(entry: Json) -> str:
    sri = sha256_hex_to_sri(str(entry["hash"]))
    pin: Json = {
        "version": str(entry.get("versionName") or ""),
        "apkName": str(entry["apkName"]),
        "architectures": {
            system: {"archStr": "universal", "hash": sri} for system in FLAKE_SYSTEMS
        },
    }
    return json.dumps(pin, indent=2, sort_keys=True) + "\n"


def render_verified(package: str, entry: Json, index_url: str, host: str) -> str:
    return (
        json.dumps(
            {
                "package": package,
                "signerFingerprints": [hex_to_fingerprint(entry["signer"])],
                "source": f"{host} F-Droid-format repository index (index-v1.json)",
                "source-url": index_url,
            },
            indent=2,
        )
        + "\n"
    )


def main(cli: argparse.Namespace) -> None:
    # --from-file only controls where the index is read from; the repo
    # identity (attribution + download URL) always comes from --repo/default.
    repo_url = REPO_ALIASES.get(cli.repo, cli.repo).rstrip("/")
    data = load_index(cli.file or "network", repo_url)
    packages = data.get("packages", {})
    if not isinstance(packages, dict) or not packages:
        print(f"unexpected index: no 'packages' map (schema {data.get('schema')})")
        sys.exit(1)
    index_url = f"{repo_url}/index-v1.json"
    host = repo_url.split("//", 1)[-1].split("/", 1)[0]
    pkgs_dir = cli.pkgs_dir or PKGS_DIR

    existing = {p.parent.name for p in pkgs_dir.rglob("package.nix")}
    planned: list[tuple[str, Json]] = []
    skipped_abi = 0
    for package, entries in sorted(packages.items()):
        if package in existing:
            continue
        if cli.only and package != cli.only:
            continue
        latest = pick_latest(cast(list[Json], entries))
        if not latest or not latest.get("hash") or not latest.get("apkName"):
            continue
        if not latest.get("versionName"):
            continue  # unpinnable: no version to pin (would be excluded by hasPin)
        if not latest.get("signer"):
            continue  # no signing certificate -> cannot produce verified.json
        if not cli.all and not is_universal(latest):
            skipped_abi += 1
            continue
        planned.append((package, latest))

    if cli.limit:
        planned = planned[: cli.limit]

    if cli.dry_run or not planned:
        print(f"{'[dry] would add:' if cli.dry_run else 'nothing to add'}")
        for package, entry in planned:
            print(
                f"  {sva.guess_category(package)}/{package}  v{entry['versionName']}  {entry['apkName']}"
            )
        print(f"(skipped {skipped_abi} per-ABI-only apps; use --all to include)")
        if not planned or cli.dry_run:
            sys.exit(0)

    created = 0
    for package, entry in planned:
        app_dir = pkgs_dir / sva.guess_category(package) / package
        app_dir.mkdir(parents=True, exist_ok=True)
        (app_dir / "package.nix").write_text(
            render_package(package, sva.derive_pname(package), repo_url)
        )
        (app_dir / "hashes.json").write_text(render_pin(entry))
        (app_dir / "verified.json").write_text(render_verified(package, entry, index_url, host))
        created += 1
        print(f"[+] {app_dir.relative_to(pkgs_dir.parent)}  v{entry['versionName']}")

    print(
        f"seeded {created} apps (flat hashes from signed index, no downloads). "
        f"Next: run `nix flake check` and `python scripts/update.py --check`."
    )


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Seed apps from a F-Droid-format repository index")
    p.add_argument(
        "--repo",
        default=DEFAULT_REPO,
        help="F-Droid-format repo base URL or alias (fdroid | izzy), "
        "e.g. https://apt.izzysoft.de/fdroid/repo",
    )
    p.add_argument(
        "--from-file",
        dest="file",
        metavar="PATH",
        help="use a local index-v1.json instead of downloading",
    )
    p.add_argument("--dry-run", action="store_true", help="print the plan, write nothing")
    p.add_argument("--limit", type=int, help="cap the number of apps seeded")
    p.add_argument("--only", metavar="APP_ID", help="seed a single package")
    p.add_argument("--all", action="store_true", help="also seed per-ABI-only APKs")
    p.add_argument(
        "--pkgs-dir", type=Path, default=PKGS_DIR, help="where to write apps (default: ./pkgs)"
    )
    return p.parse_args()


if __name__ == "__main__":
    main(parse_args())
