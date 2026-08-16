#!/usr/bin/env python3
"""Async updater for the Android APK repository.

Each app lives in ``pkgs/<category>/<app-id>/`` with:

    package.nix   static template that reads ./hashes.json
    hashes.json   generated lockfile:
                  {version, architectures: {system: {archStr, hash}}}
                  (f-droid apps additionally carry the exact ``apkName``)
    history.json  version history, newest first:
                  {versions: [{version, versionCode, date?, size?}]}
                  (written by `update.py --history`)

For every app it:

  * apk-pure: queries the latest *fetchable* version (via `apkeep -l`),
    downloads the APK for each requested architecture, computes the Nix SRI
    hash (`nix hash path`, matching the recursive FODs fetchApk builds) and
    rewrites ``hashes.json``.

  * f-droid: the version, exact file name and sha256 of every APK are already
    published in the repository's signed index, so updates read that index and
    pin the flat file hash directly - no download required.

  * github-releases: resolves the latest release via the GitHub API, picks the
    best `.apk` asset (universal > arm64-v8a > x86_64 > any), downloads it and
    pins the flat file hash (version = release tag, asset name in ``apkName``).

Usage::

    python scripts/update.py                      # update everything, write
    python scripts/update.py --check              # only report, never modify
    python scripts/update.py --dry-run            # compute hashes, don't write
    python scripts/update.py --only org.thoughtcrime.securesms
    python scripts/update.py --rehash             # recompute hashes for pinned versions
    python scripts/update.py --systems x86_64-linux=universal,aarch64-linux=arm64-v8a
                                                   # pin extra architectures per Nix system
    python scripts/update.py --history            # fetch per-app version history (history.json)
    python scripts/update.py --history --check    # report history changes without writing

Google Play / Aurora (`source = "google-play"` / `"aurora"`) cannot pin
versions or be auto-detected; they are skipped unless ``--rehash`` is given,
with credentials read from the environment:

    GOOGLE_EMAIL=you@gmail.com \\
    GOOGLE_AUTH_TOKEN=ya29.a0... \\
    python scripts/update.py --rehash --only com.my.app
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import hashlib
import json
import logging
import os
import platform
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, cast

import httpx
from bs4 import BeautifulSoup

# JSON payloads from external APIs/indexes/HTML attributes are untyped by
# nature; Json keeps that explicit at the boundary while the rest of the code
# stays strictly typed.
Json = dict[str, Any]

log = logging.getLogger("update")

REPO_ROOT = Path(__file__).resolve().parent.parent
PKGS_DIR = REPO_ROOT / "pkgs"

# On some networks apkpure.com is blocked; apkpure.net is a reliable mirror.
APKPURE_BASES = os.environ.get("APKPURE_BASES", "https://apkpure.com,https://apkpure.net").split(
    ","
)

CONCURRENCY_LIMIT = int(os.environ.get("CONCURRENCY_LIMIT", "5"))
CLI_TIMEOUT = 120

USER_AGENT = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/120.0 Safari/537.36"
)
HEADERS = {"User-Agent": USER_AGENT}
TIMEOUT = httpx.Timeout(30.0)

# Normalise our source names onto apkeep's canonical `-d` values. Sources
# with no apkeep equivalent (f-droid, github-releases) keep their own name.
SOURCE_NAMES = {
    "apk-pure": "apk-pure",
    "apkpure": "apk-pure",
    "apk-pure.com": "apk-pure",
    "google-play": "google-play",
    "googleplay": "google-play",
    "play": "google-play",
    "aurora": "google-play",
    "f-droid": "f-droid",
    "fdroid": "f-droid",
    "github-releases": "github-releases",
    "github": "github-releases",
    "huawei-app-gallery": "huawei-app-gallery",
    "huawei": "huawei-app-gallery",
}

# Sources where apkeep can pin an exact @version (and list versions).
VERSIONED_SOURCES = {"apk-pure", "f-droid"}

# Sources that update.py can auto-update (resolve the latest release/version)
# without user-provided credentials.
AUTO_UPDATE_SOURCES = VERSIONED_SOURCES | {"github-releases"}

# Direct-download sources: pinned by exact file name at a deterministic URL,
# hashed flat (the file's own sha256), no apkeep involved.
DIRECT_SOURCES = {"f-droid", "github-releases"}

# Nix system -> Android ABI (used when explicitly pinning non-universal ABIs).
ABI_TO_SYSTEM = {
    "x86_64": "x86_64-linux",
    "x86": "i686-linux",
    "arm64-v8a": "aarch64-linux",
    "armeabi-v7a": "armv7l-linux",
    "armeabi": "armv6l-linux",
}

_RE_SOURCE = re.compile(r'source\s*=\s*"([^"]+)"')
_RE_REPO_URL = re.compile(r'repoUrl\s*=\s*"([^"]+)"')
_RE_GH_REPO = re.compile(r'ghRepo\s*=\s*"([^"]+)"')

GITHUB_API = "https://api.github.com/repos"

# Default F-Droid-format repo (f-droid.org main repo); apps from other
# F-Droid-format repos (e.g. IzzyOnDroid) pin their own repoUrl in package.nix.
DEFAULT_FDROID_REPO = "https://f-droid.org/repo"

# Nix systems pinned by the flake; f-droid apps can carry the same flat hash
# under every system because the file hash is system-independent.
FLAKE_SYSTEMS = ["x86_64-linux", "aarch64-linux", "aarch64-darwin"]


class Package:
    def __init__(self, app_dir: Path):
        self.dir = app_dir
        self.app_id = app_dir.name
        self.package_path = app_dir / "package.nix"
        self.pin_path = app_dir / "hashes.json"
        self.history_path = app_dir / "history.json"
        raw_source = _RE_SOURCE.search(self.package_path.read_text())
        self.source = SOURCE_NAMES.get(
            raw_source.group(1).strip() if raw_source else "", "apk-pure"
        )
        self.pin = self._load_pin()

    def _load_pin(self) -> Json:
        if self.pin_path.exists():
            try:
                return cast(Json, json.loads(self.pin_path.read_text()))
            except json.JSONDecodeError:
                log.warning("%s: corrupt hashes.json, regenerating", self.app_id)
        return {"version": "", "architectures": {}}

    @property
    def repo_url(self) -> str:
        m = _RE_REPO_URL.search(self.package_path.read_text())
        return m.group(1).strip() if m else DEFAULT_FDROID_REPO

    @property
    def gh_repo(self) -> str | None:
        """`owner/repo` for github-releases apps (None for other sources)."""
        m = _RE_GH_REPO.search(self.package_path.read_text())
        return m.group(1).strip() if m else None

    @property
    def verified_fingerprints(self) -> list[str]:
        path = self.dir / "verified.json"
        if not path.exists():
            return []
        data = cast(Json, json.loads(path.read_text()))
        return [
            fp.upper().replace(" ", "").replace(":", "")
            for fp in data.get("signerFingerprints", [])
        ]

    @property
    def version(self) -> str:
        return str(self.pin.get("version") or "")

    def write_pin(self) -> None:
        self.pin_path.write_text(json.dumps(self.pin, indent=2, sort_keys=True) + "\n")

    def record_fingerprints(self, fingerprints: list[str]) -> bool:
        """Store observed signer fingerprints into verified.json (idempotent).

        APKPure publishes no signer database, so seeds carry an empty
        ``signerFingerprints`` list; the first download verified with apksigner
        records the real fingerprints here, after which every update re-checks
        against them. Returns True when the file changed.
        """
        path = self.dir / "verified.json"
        if not path.exists():
            return False
        data = cast(Json, json.loads(path.read_text()))
        existing = {_normalize_sha256(fp) for fp in data.get("signerFingerprints", [])}
        new = [
            _normalize_sha256(fp) for fp in fingerprints if _normalize_sha256(fp) not in existing
        ]
        if not new:
            return False
        data["signerFingerprints"] = sorted(existing | {_normalize_sha256(fp) for fp in new})
        path.write_text(json.dumps(data, indent=2) + "\n")
        return True

    def load_history(self) -> Json:
        if self.history_path.exists():
            try:
                return cast(Json, json.loads(self.history_path.read_text()))
            except json.JSONDecodeError:
                log.warning("%s: corrupt history.json, regenerating", self.app_id)
        return {"versions": []}

    def write_history(self, versions: list[dict[str, Any]]) -> None:
        self.history_path.write_text(json.dumps({"versions": versions}, indent=2) + "\n")


def current_system() -> str:
    machine = platform.machine().lower()
    os_name = "darwin" if platform.system() == "Darwin" else "linux"
    table = {
        "x86_64": "x86_64",
        "amd64": "x86_64",
        "aarch64": "aarch64",
        "arm64": "aarch64",
        "i686": "i686",
        "i386": "i686",
    }
    arch = table.get(machine)
    if arch is None and machine.startswith("arm"):
        arch = "armv7l"
    if arch is None:
        arch = machine
    return f"{arch}-{os_name}"


def build_apkeep_cmd(app_id: str, version: str, source: str, arch: str, outdir: Path) -> list[str]:
    pin = f"@{version}" if source in VERSIONED_SOURCES else ""
    cmd = ["apkeep", "-a", f"{app_id}{pin}", "-d", source]
    if arch != "universal":
        cmd += ["-o", f"arch={arch}"]
    extra_options = os.environ.get("SOURCE_OPTIONS", "")
    if extra_options:
        cmd += ["-o", extra_options]

    if source == "google-play":
        email = os.environ.get("GOOGLE_EMAIL")
        aas_token = os.environ.get("GOOGLE_AAS_TOKEN")
        auth_token = os.environ.get("GOOGLE_AUTH_TOKEN")
        if email:
            cmd += ["-e", email]
        if aas_token:
            cmd += ["-t", aas_token]
        elif auth_token:
            cmd += ["--auth-token", auth_token]
        if os.environ.get("GOOGLE_ACCEPT_TOS"):
            cmd += ["--accept-tos"]

    cmd.append(str(outdir))
    return cmd


def sha256_hex_to_sri(hexstr: str) -> str:
    """Convert a hex sha256 (as published in F-Droid indexes) to a Nix SRI."""
    return "sha256-" + base64.b64encode(bytes.fromhex(hexstr)).decode()


def compute_sri(
    app_id: str, version: str, source: str, arch: str, outdir: Path
) -> tuple[str, Path]:
    """Download the APK and hash the layout the derivation will produce.

    fetchApk.nix installs into ``$out/share/apk/<original-name>``; the NAR hash
    of that layout only matches the download if we stage the identical tree.
    Returns ``(sri, apk_path)``.
    """
    raw = outdir / "raw"
    raw.mkdir()
    subprocess.run(
        build_apkeep_cmd(app_id, version, source, arch, raw),
        check=True,
        timeout=CLI_TIMEOUT,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )
    files = list(raw.glob("*.apk")) + list(raw.glob("*.xapk"))
    if not files:
        raise FileNotFoundError(f"apkeep produced no APK for {app_id}")

    staged = outdir / "staged"
    dest = staged / "share" / "apk" / files[0].name
    dest.parent.mkdir(parents=True)
    dest.write_bytes(files[0].read_bytes())

    sri = subprocess.check_output(
        ["nix", "hash", "path", "--type", "sha256", str(staged)], text=True
    ).strip()
    return sri, files[0]


def _normalize_sha256(fp: str) -> str:
    return "".join(fp.split()).replace(":", "").upper()


def apksigner_fingerprints(apk_path: Path) -> list[str]:
    """SHA-256 certificate digest(s) of the APK's signer(s)."""
    out = subprocess.run(
        ["apksigner", "verify", "--print-certs", str(apk_path)],
        capture_output=True,
        text=True,
        timeout=CLI_TIMEOUT,
        check=True,
    )
    fps = []
    for line in out.stdout.splitlines():
        m = re.search(r"SHA-256 (?:digest|fingerprint):\s*([0-9A-Fa-f:]+)", line)
        if m:
            fps.append(_normalize_sha256(m.group(1)))
    if not fps:
        raise LookupError(f"no signer fingerprint found for {apk_path.name}")
    return fps


async def run_apkeep_list_versions(app_id: str, source: str) -> list[str]:
    """Versions that apkeep can actually download for a pinned source."""
    out = await asyncio.to_thread(
        subprocess.run,
        ["apkeep", "-l", "-a", app_id, "-d", source, "."],
        capture_output=True,
        text=True,
        timeout=CLI_TIMEOUT,
    )
    if out.returncode != 0:
        raise subprocess.SubprocessError(out.stderr.strip())

    versions = []
    for line in out.stdout.splitlines():
        if not line.lstrip().startswith("|"):
            continue
        for token in line.split("|")[-1].split(","):
            token = token.strip()
            if re.fullmatch(r"\d+(\.\d+)+", token):  # e.g. 8.22.2, 0.118.0
                versions.append(token)
    return versions


def version_key(version: str) -> tuple[int, ...]:
    return tuple(int(p) if p.isdigit() else -1 for p in version.split("."))


async def get_latest_version(app_id: str, source: str) -> str:
    """Latest fetchable version, preferring `apkeep -l` (page scrape as backup)."""
    try:
        versions = await run_apkeep_list_versions(app_id, source)
        if versions:
            return max(versions, key=version_key)
    except (subprocess.SubprocessError, OSError):
        pass

    base = APKPURE_BASES[0]
    detail = await _apkpure_detail(base, app_id)
    m = re.search(r'"version"\s*:\s*"([0-9][^"]*)"', detail)
    if m:
        return m.group(1)

    soup = BeautifulSoup(detail, "html.parser")
    row = soup.select_one("[data-dt-version]")
    if row is not None:
        version = row.get("data-dt-version")
        if isinstance(version, str) and version:
            return version
    raise LookupError(f"could not determine latest version for {app_id}")


async def _apkpure_get(base: str, path: str) -> str:
    """GET an APKPure page, trying every configured base as a mirror."""

    async def _get(url: str) -> str:
        async with httpx.AsyncClient(headers=HEADERS, timeout=TIMEOUT) as client:
            resp = await client.get(url)
            resp.raise_for_status()
            return resp.text

    try:
        return await _get(f"{base}{path}")
    except httpx.HTTPError:
        for fallback in APKPURE_BASES:
            if fallback == base:
                continue
            try:
                return await _get(f"{fallback}{path}")
            except httpx.HTTPError:
                continue
        raise


async def _apkpure_slug(base: str, app_id: str) -> str:
    """Resolve the APKPure page slug for an app id via search.

    APKPure URLs look like ``/<slug>/<app-id>`` (e.g. ``/slack/com.Slack``);
    the search page is the only place that maps an app id to its slug. Returns
    the slug only (no leading slash), e.g. ``"slack"``.
    """
    soup = BeautifulSoup(await _apkpure_get(base, f"/search?q={app_id}"), "html.parser")
    for a in soup.find_all("a", href=True):
        href = a.get("href")
        if isinstance(href, str) and href.startswith("/") and href.endswith(f"/{app_id}"):
            return href.strip("/").rsplit("/", 1)[0]
    raise LookupError(f"no APKPure page found for {app_id}")


async def _apkpure_detail(base: str, app_id: str) -> str:
    slug = await _apkpure_slug(base, app_id)
    return await _apkpure_get(base, f"/{slug}/{app_id}")


def parse_version_history(html: str) -> list[dict[str, Any]]:
    """Parse the APKPure ``/versions`` page into a version history.

    Each ``li.version`` row carries the version name and version code in data
    attributes plus a human-readable date; rows hidden behind the "Show More"
    button are included too (they are in the initial HTML). Returns a list of
    ``{version, versionCode, date?, size?}`` dicts, newest first (page order).
    """
    soup = BeautifulSoup(html, "html.parser")
    history: list[dict[str, Any]] = []
    for row in soup.find_all("li", class_="version"):
        version = row.get("data-dt-version")
        code = row.get("data-dt-version-code")
        if not isinstance(version, str) or not version:
            continue
        entry: dict[str, Any] = {"version": version}
        if isinstance(code, str) and code.isdigit():
            entry["versionCode"] = int(code)
        date_el = row.find("p", class_="version-date")
        if date_el:
            m = re.search(r"Updated on\s+(.+)", date_el.get_text(" ", strip=True))
            if m:
                entry["date"] = m.group(1).strip()
        info_el = row.find("div", class_="additional-info")
        if info_el:
            m = re.search(r"(\d+(?:\.\d+)?\s*(?:MB|GB))", info_el.get_text(" ", strip=True))
            if m:
                entry["size"] = m.group(1)
        history.append(entry)
    return history


async def fetch_apkpure_history(app_id: str) -> list[dict[str, Any]]:
    """Fetch the APKPure version history for an app (newest first).

    Merges two sources: the ``/versions`` page (richest: versionCode + date +
    size, but only ~10 entries) and ``apkeep -l`` (the full list of versions
    apkeep can actually download, no codes/dates). The page is the primary
    source; when it is unavailable (geo-blocked slugs, missing pages) the
    apkeep list alone still yields a usable history.
    """
    base = APKPURE_BASES[0]
    page_versions: list[dict[str, Any]] = []
    try:
        slug = await _apkpure_slug(base, app_id)
        html = await _apkpure_get(base, f"/{slug}/{app_id}/versions")
        page_versions = parse_version_history(html)
    except (httpx.HTTPError, LookupError):
        page_versions = []

    try:
        listed = await run_apkeep_list_versions(app_id, "apk-pure")
    except (subprocess.SubprocessError, OSError):
        listed = []

    if not page_versions and not listed:
        return []

    seen = {v["version"] for v in page_versions}
    merged = list(page_versions)
    for version in listed:
        if version not in seen:
            merged.append({"version": version})
            seen.add(version)

    # The APKPure page is not reliably ordered (an old build can appear right
    # after the newest), so sort newest-first by versionCode when known; the
    # code-less entries from `apkeep -l` (older, unlisted) go to the end.
    def sort_key(entry: dict[str, Any]) -> tuple[bool, int]:
        return (entry.get("versionCode") is None, -(entry.get("versionCode") or 0))

    merged.sort(key=sort_key)
    return merged


async def fetch_fdroid_index(repo_url: str) -> Json:
    """Fetch and parse a F-Droid-format ``index-v1.json``."""
    url = f"{repo_url.rstrip('/')}/index-v1.json"
    async with httpx.AsyncClient(headers=HEADERS, timeout=httpx.Timeout(120.0)) as client:
        resp = await client.get(url)
        resp.raise_for_status()
        return cast(Json, resp.json())


def pick_github_asset(release: Json) -> Json | None:
    """Pick the best APK asset from a GitHub release dict.

    Preference order: universal APK > arm64-v8a > x86_64 > any .apk. GitHub
    release pages are the only source of truth here (no index to consult), so
    we match on the asset name patterns the projects publish.
    """
    apks = cast(list[Json], release.get("assets", []))
    apks = [a for a in apks if str(a.get("name") or "").endswith(".apk")]
    if not apks:
        return None
    for pattern in ("universal", "arm64-v8a", "x86_64"):
        for asset in apks:
            if pattern.lower() in str(asset.get("name", "")).lower():
                return asset
    return apks[0]


async def github_latest_release(gh_repo: str) -> Json:
    """Latest non-prerelease release of a GitHub repo (GitHub API)."""
    url = f"{GITHUB_API}/{gh_repo}/releases/latest"
    async with httpx.AsyncClient(
        headers=HEADERS, timeout=httpx.Timeout(60.0), follow_redirects=True
    ) as client:
        resp = await client.get(url)
        resp.raise_for_status()
        return cast(Json, resp.json())


async def compute_github_sri(release: Json, asset: Json) -> str:
    """Download a GitHub release asset and return its flat sha256 SRI.

    GitHub publishes no hashes, so the pin is computed from the actual bytes
    (matching fetchApk's flat `outputHashMode` for github-releases apps).
    """
    url = str(asset["browser_download_url"])
    digest = hashlib.sha256()
    async with httpx.AsyncClient(
        headers=HEADERS, timeout=httpx.Timeout(600.0), follow_redirects=True
    ) as client:
        async with client.stream("GET", url) as resp:
            resp.raise_for_status()
            async for chunk in resp.aiter_bytes():
                digest.update(chunk)
    return "sha256-" + base64.b64encode(digest.digest()).decode()


async def github_release_history(gh_repo: str) -> list[dict[str, Any]] | None:
    """Release history of a GitHub repo (newest first, via the API).

    Returns ``{version, date?, size?}`` entries; ``version`` is the release
    tag. Returns None when the repo has no releases at all.
    """
    url = f"{GITHUB_API}/{gh_repo}/releases?per_page=100"
    async with httpx.AsyncClient(
        headers=HEADERS, timeout=httpx.Timeout(60.0), follow_redirects=True
    ) as client:
        resp = await client.get(url)
        resp.raise_for_status()
        releases = cast(list[Json], resp.json())
    versions: list[dict[str, Any]] = []
    for rel in releases:
        tag = rel.get("tag_name")
        if not isinstance(tag, str) or not tag:
            continue
        entry: dict[str, Any] = {"version": tag}
        published = rel.get("published_at")
        if isinstance(published, str):
            entry["date"] = published[:10]
        asset = pick_github_asset(rel)
        if asset and isinstance(asset.get("size"), int):
            entry["size"] = human_size(asset["size"])
        versions.append(entry)
    return versions or None


def human_size(num_bytes: float) -> str:
    """Format a byte count as e.g. `73.5 MB` (matching APKPure's sizes)."""
    for unit in ("B", "KB", "MB", "GB"):
        if num_bytes < 1024 or unit == "GB":
            return (
                f"{num_bytes:.1f} {unit}".replace(".0 ", " ") if unit != "B" else f"{num_bytes} B"
            )
        num_bytes /= 1024
    return f"{num_bytes:.1f} GB"


async def load_fdroid_indexes(pkgs: list[Package]) -> dict[str, Json | None]:
    """Fetch each distinct F-Droid-format index once (they are large)."""
    urls = sorted({p.repo_url for p in pkgs if p.source == "f-droid"})
    indexes: dict[str, Json | None] = {}
    for url in urls:
        try:
            indexes[url] = await fetch_fdroid_index(url)
        except (httpx.HTTPError, ValueError) as exc:
            log.warning("could not fetch f-droid index %s: %s", url, exc)
            indexes[url] = None
    return indexes


async def update_fdroid_package(pkg: Package, indexes: dict[str, Json | None]) -> str:
    """Update an f-droid app from its repo's signed index (no download)."""
    index = indexes.get(pkg.repo_url)
    if index is None:
        return f"[warn] {pkg.app_id}: f-droid index unavailable for {pkg.repo_url}"
    entries = cast(list[Json], index.get("packages", {}).get(pkg.app_id) or [])
    if not entries:
        return f"[warn] {pkg.app_id}: not present in {pkg.repo_url} index"

    latest = max(entries, key=lambda e: int(e.get("versionCode") or 0))
    version = str(latest.get("versionName") or "")
    if not version:
        return f"[warn] {pkg.app_id}: index entry has no versionName"
    if not args.rehash and version == pkg.version:
        return f"[skip] {pkg.app_id}: already at {version}"

    sri = sha256_hex_to_sri(str(latest["hash"]))
    new_pin: Json = {"version": version, "apkName": str(latest["apkName"]), "architectures": {}}
    for system, arch in requested_arch_pins(args.systems):
        new_pin["architectures"][system] = {"archStr": arch or "universal", "hash": sri}
    # f-droid flat hashes are system-independent: the same APK file (and thus
    # the same hash) serves every Nix system. A version bump changes the hash
    # for ALL systems, so stamp the fresh hash onto every previously pinned
    # system - preserving the old entries would leave stale (broken) hashes.
    for system in pkg.pin.get("architectures", {}):
        new_pin["architectures"].setdefault(system, {"archStr": "universal", "hash": sri})

    if args.dry_run or args.check:
        return f"[dry]  {pkg.app_id}: {pkg.version} -> {version} {new_pin['architectures']}"
    pkg.pin = new_pin
    pkg.write_pin()
    return f"[upd]  {pkg.app_id}: {pkg.version or '(new)'} -> {version} (flat sha256 from index)"


def requested_arch_pins(systems: list[str]) -> list[tuple[str, str]]:
    """Parse `SYSTEM[=ABI]` specs into (system-key, archStr) pairs.

    The default ABI is "universal" (the single artifact apkeep serves by
    default); pass e.g. `x86_64-linux=x86_64` to pin a specific ABI.)
    """
    pins = []
    for token in systems:
        system, _, arch = token.partition("=")
        pins.append((system, arch or "universal"))
    return pins


async def update_package(
    pkg: Package,
    semaphore: asyncio.Semaphore,
    fdroid_indexes: dict[str, Json | None] | None = None,
) -> str:
    async with semaphore:
        if pkg.source not in AUTO_UPDATE_SOURCES and not args.rehash:
            return f"[skip] {pkg.app_id}: {pkg.source} cannot be auto-updated (use --rehash)"
        if pkg.source == "f-droid":
            return await update_fdroid_package(pkg, fdroid_indexes or {})
        if pkg.source == "github-releases":
            return await update_github_package(pkg)

        try:
            latest = await get_latest_version(pkg.app_id, pkg.source)
        except (httpx.HTTPError, LookupError, subprocess.SubprocessError) as exc:
            return f"[warn] {pkg.app_id}: {exc}"

        version = latest if latest != pkg.version and not args.rehash else pkg.version
        if not args.rehash and not version:
            return f"[warn] {pkg.app_id}: no version known"

        hashes: dict[str, str] = {}
        ok = True
        # The downloaded APK must outlive compute_sri's scratch dir: apksigner
        # verifies it AFTER the loop, so keep one stable copy around.
        with tempfile.TemporaryDirectory() as keep:
            kept_apk: Path | None = None
            for system, arch in requested_arch_pins(args.systems):
                try:
                    with tempfile.TemporaryDirectory() as tmp:
                        sri, apk_path = await asyncio.to_thread(
                            compute_sri, pkg.app_id, version, pkg.source, arch, Path(tmp)
                        )
                        hashes[system] = sri
                        if kept_apk is None:
                            kept_apk = Path(keep) / apk_path.name
                            kept_apk.write_bytes(apk_path.read_bytes())
                except (subprocess.SubprocessError, FileNotFoundError) as exc:
                    # SubprocessError covers CalledProcessError AND TimeoutExpired,
                    # so one slow/flaky download degrades that package instead of
                    # aborting the whole run.
                    stderr = (getattr(exc, "stderr", b"") or b"").decode().strip()
                    ok = False
                    digest = stderr or str(exc)
            if not ok:
                return f"[fail] {pkg.app_id}@{version}: one or more architectures failed ({digest})"

            verified = []
            expected = pkg.verified_fingerprints
            if kept_apk is not None and not args.skip_verify and _command_exists("apksigner"):
                found = await asyncio.to_thread(apksigner_fingerprints, kept_apk)
                if expected:
                    match = bool(set(found) & set(expected))
                    verified = [f"{'ok' if match else 'MISMATCH'} signer {pkg.app_id}"]
                    if not match:
                        return f"[fail] {pkg.app_id}@{version}: signer cert mismatch ({found} not in {expected})"
                elif (pkg.dir / "verified.json").exists() and not args.dry_run and not args.check:
                    # First verified download of an apk-pure seed: record the
                    # observed signer so future updates can re-check it.
                    if pkg.record_fingerprints(found):
                        verified = [f"recorded signer {pkg.app_id}"]
            elif expected and not args.dry_run and not args.check and not args.skip_verify:
                log.warning(
                    "not verifying signer for %s: apksigner not found or download not staged",
                    pkg.app_id,
                )

            if not hashes:
                return f"[warn] {pkg.app_id}: no architectures requested"

            new_pin: Json = {"version": version, "architectures": {}}
            for system, arch in requested_arch_pins(args.systems):
                new_pin["architectures"][system] = {"archStr": arch, "hash": hashes[system]}
            # Preserve architecture pins that were not recomputed this run.
            for system, entry in pkg.pin.get("architectures", {}).items():
                new_pin["architectures"].setdefault(system, entry)

    if args.dry_run or args.check:
        return f"[dry]  {pkg.app_id}: {pkg.version} -> {version} {new_pin['architectures']} {(' '.join(verified))}"
    pkg.pin = new_pin
    pkg.write_pin()
    suffix = f" ({' '.join(verified)})" if verified else ""
    return f"[upd]  {pkg.app_id}: {pkg.version or '(new)'} -> {version}{suffix}"


async def update_github_package(pkg: Package) -> str:
    """Update a github-releases app: pin the latest release's best APK asset.

    GitHub publishes no hashes or index, so the latest release is resolved via
    the GitHub API and the chosen asset is downloaded and hashed flat (the
    file's own sha256), matching fetchApk's flat output mode for this source.
    The same flat hash is stamped onto every pinned Nix system, like f-droid.
    """
    gh_repo = pkg.gh_repo
    if not gh_repo:
        return f"[fail] {pkg.app_id}: github-releases source missing `ghRepo` in package.nix"
    try:
        release = await github_latest_release(gh_repo)
    except httpx.HTTPError as exc:
        return f"[warn] {pkg.app_id}: {exc}"
    tag = release.get("tag_name") or ""
    if not tag:
        return f"[warn] {pkg.app_id}: GitHub release has no tag"
    asset = pick_github_asset(release)
    if asset is None:
        return f"[warn] {pkg.app_id}: no .apk asset in {gh_repo} release {tag}"
    asset_name = asset.get("name") or ""
    if not args.rehash and tag == pkg.version and asset_name == pkg.pin.get("apkName"):
        return f"[skip] {pkg.app_id}: already at {tag} ({asset_name})"

    sri = await compute_github_sri(release, asset)
    new_pin: Json = {"version": tag, "apkName": asset_name, "architectures": {}}
    for system, arch in requested_arch_pins(args.systems):
        new_pin["architectures"][system] = {"archStr": arch or "universal", "hash": sri}
    for system in pkg.pin.get("architectures", {}):
        new_pin["architectures"].setdefault(system, {"archStr": "universal", "hash": sri})

    if args.dry_run or args.check:
        return f"[dry]  {pkg.app_id}: {pkg.version or '(new)'} -> {tag} ({asset_name}) {sri}"
    pkg.pin = new_pin
    pkg.write_pin()
    return f"[upd]  {pkg.app_id}: {pkg.version or '(new)'} -> {tag} ({asset_name})"


def find_packages() -> list[Package]:
    pkgs: list[Package] = []
    for category in sorted(PKGS_DIR.iterdir()):
        if not category.is_dir():
            continue
        for app_dir in sorted(category.iterdir()):
            if (app_dir / "package.nix").exists():
                pkgs.append(Package(app_dir))
    return pkgs


async def history_for_fdroid(pkg: Package, index: Json) -> list[dict[str, Any]] | None:
    """Version history from the repo's signed index (every APK entry)."""
    entries = cast(list[Json], index.get("packages", {}).get(pkg.app_id) or [])
    if not entries:
        return None
    versions: list[dict[str, Any]] = []
    for e in entries:
        name = e.get("versionName")
        if not isinstance(name, str) or not name:
            continue
        entry: dict[str, Any] = {"version": name, "versionCode": int(e.get("versionCode") or 0)}
        added = e.get("added")
        if isinstance(added, str):
            entry["date"] = added[:10]
        versions.append(entry)
    versions.sort(key=lambda v: int(v.get("versionCode") or 0), reverse=True)
    return versions


async def update_history(
    pkg: Package,
    semaphore: asyncio.Semaphore,
    fdroid_indexes: dict[str, Json | None] | None = None,
) -> str:
    """Fetch and write an app's version history (history.json)."""
    async with semaphore:
        if pkg.source == "f-droid":
            index = (fdroid_indexes or {}).get(pkg.repo_url)
            if index is None:
                return f"[warn] {pkg.app_id}: f-droid index unavailable for {pkg.repo_url}"
            versions = await history_for_fdroid(pkg, index)
            if versions is None:
                return f"[warn] {pkg.app_id}: not present in {pkg.repo_url} index"
        elif pkg.source == "github-releases":
            gh_repo = pkg.gh_repo
            if not gh_repo:
                return (
                    f"[warn] {pkg.app_id}: github-releases source missing `ghRepo` in package.nix"
                )
            try:
                versions = await github_release_history(gh_repo)
            except httpx.HTTPError as exc:
                return f"[warn] {pkg.app_id}: {exc}"
            if versions is None:
                return f"[warn] {pkg.app_id}: {gh_repo} has no releases"
        else:
            try:
                versions = await fetch_apkpure_history(pkg.app_id)
            except (httpx.HTTPError, LookupError, subprocess.SubprocessError) as exc:
                return f"[warn] {pkg.app_id}: {exc}"
            if not versions:
                return f"[warn] {pkg.app_id}: APKPure reports no version history"

        old = pkg.load_history().get("versions", [])
        if versions == old:
            return f"[skip] {pkg.app_id}: history unchanged ({len(versions)} versions)"
        if args.dry_run or args.check:
            return f"[dry]  {pkg.app_id}: {len(old)} -> {len(versions)} versions"
        pkg.write_history(versions)
        newest = versions[0].get("version") if versions else "?"
        return f"[hist] {pkg.app_id}: recorded {len(versions)} versions (newest {newest})"


async def main(cli: argparse.Namespace) -> None:
    pkgs = find_packages()
    if cli.only:
        pkgs = [p for p in pkgs if p.app_id == cli.only]
        if not pkgs:
            log.error("no package found for app id: %s", cli.only)
            sys.exit(1)

    if cli.history:
        # Version-history mode: no apkeep/nix needed (f-droid history comes
        # from the index, apk-pure from the APKPure versions page).
        fdroid_indexes = await load_fdroid_indexes(pkgs)
        semaphore = asyncio.Semaphore(CONCURRENCY_LIMIT)
        results = await asyncio.gather(
            *(update_history(p, semaphore, fdroid_indexes) for p in pkgs)
        )
        for line in results:
            print(line)
        return

    # apkeep is only needed for sources that download via apkeep (apk-pure and
    # the play-style sources); nix is only needed to hash the staged layout
    # (compute_sri). Direct sources (f-droid, github-releases) hash flat bytes
    # or read the index, so they work without either tool.
    needs_apkeep = any(p.source not in DIRECT_SOURCES for p in pkgs)
    needs_nix = any(p.source == "apk-pure" for p in pkgs)
    if needs_apkeep and not _command_exists("apkeep"):
        log.error("missing required tool: apkeep")
        sys.exit(1)
    if needs_nix and not _command_exists("nix"):
        log.error("missing required tool: nix")
        sys.exit(1)

    fdroid_indexes = await load_fdroid_indexes(pkgs)
    semaphore = asyncio.Semaphore(CONCURRENCY_LIMIT)
    results = await asyncio.gather(*(update_package(p, semaphore, fdroid_indexes) for p in pkgs))
    for line in results:
        print(line)


def _command_exists(name: str) -> bool:
    return any(
        (Path(p) / name).is_file() for p in os.environ.get("PATH", "").split(os.pathsep) if p
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Update Android APK packages")
    parser.add_argument("--check", action="store_true", help="only report, never modify")
    parser.add_argument("--dry-run", action="store_true", help="compute hashes, don't write")
    parser.add_argument(
        "--rehash",
        action="store_true",
        help="recompute hashes for pinned versions (supports google-play/aurora)",
    )
    parser.add_argument(
        "--history",
        action="store_true",
        help="fetch per-app version history (history.json) instead of updating pins",
    )
    parser.add_argument("--only", metavar="APP_ID", help="only update this app id")
    parser.add_argument(
        "--systems",
        metavar="SYSTEM[=ABI]",
        default=[f"{current_system()}=universal"],
        nargs="+",
        help="how to pin architectures, e.g. x86_64-linux=universal, "
        "aarch64-linux=arm64-v8a (default: current system, universal)",
    )
    parser.add_argument(
        "--skip-verify",
        action="store_true",
        help="skip apksigner fingerprint verification (default: verify when apksigner exists)",
    )
    return parser.parse_args()


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    args = parse_args()
    asyncio.run(main(args))
