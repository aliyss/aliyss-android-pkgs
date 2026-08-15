#!/usr/bin/env python3
"""Async updater for the Android APK repository.

Each app lives in ``pkgs/<category>/<app-id>/`` with:

    package.nix   static template that reads ./hashes.json
    hashes.json   generated lockfile:
                  {version, architectures: {system: {archStr, hash}}}
                  (f-droid apps additionally carry the exact ``apkName``)

For every app it:

  * apk-pure: queries the latest *fetchable* version (via `apkeep -l`),
    downloads the APK for each requested architecture, computes the Nix SRI
    hash (`nix hash path`, matching the recursive FODs fetchApk builds) and
    rewrites ``hashes.json``.

  * f-droid: the version, exact file name and sha256 of every APK are already
    published in the repository's signed index, so updates read that index and
    pin the flat file hash directly - no download required.

Usage::

    python scripts/update.py                      # update everything, write
    python scripts/update.py --check              # only report, never modify
    python scripts/update.py --dry-run            # compute hashes, don't write
    python scripts/update.py --only org.thoughtcrime.securesms
    python scripts/update.py --rehash             # recompute hashes for pinned versions
    python scripts/update.py --systems x86_64-linux=universal,aarch64-linux=arm64-v8a
                                                   # pin extra architectures per Nix system

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
import json
import logging
import os
import platform
import re
import subprocess
import sys
import tempfile
from pathlib import Path

import httpx
from bs4 import BeautifulSoup

log = logging.getLogger("update")

REPO_ROOT = Path(__file__).resolve().parent.parent
PKGS_DIR = REPO_ROOT / "pkgs"

# On some networks apkpure.com is blocked; apkpure.net is a reliable mirror.
APKPURE_BASES = os.environ.get(
    "APKPURE_BASES", "https://apkpure.com,https://apkpure.net"
).split(",")

CONCURRENCY_LIMIT = int(os.environ.get("CONCURRENCY_LIMIT", "5"))
CLI_TIMEOUT = 120

USER_AGENT = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/120.0 Safari/537.36"
)
HEADERS = {"User-Agent": USER_AGENT}
TIMEOUT = httpx.Timeout(30.0)

# Normalise our source names onto apkeep's canonical `-d` values.
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
    "huawei-app-gallery": "huawei-app-gallery",
    "huawei": "huawei-app-gallery",
}

# Sources where apkeep can pin an exact @version (and list versions).
VERSIONED_SOURCES = {"apk-pure", "f-droid"}

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
        raw_source = _RE_SOURCE.search(self.package_path.read_text())
        self.source = SOURCE_NAMES.get(
            raw_source.group(1).strip() if raw_source else None, "apk-pure"
        )
        self.pin = self._load_pin()

    def _load_pin(self) -> dict:
        if self.pin_path.exists():
            try:
                return json.loads(self.pin_path.read_text())
            except json.JSONDecodeError:
                log.warning("%s: corrupt hashes.json, regenerating", self.app_id)
        return {"version": "", "architectures": {}}

    @property
    def repo_url(self) -> str:
        m = _RE_REPO_URL.search(self.package_path.read_text())
        return m.group(1).strip() if m else DEFAULT_FDROID_REPO

    @property
    def verified_fingerprints(self) -> list[str]:
        path = self.dir / "verified.json"
        if not path.exists():
            return []
        data = json.loads(path.read_text())
        return [fp.upper().replace(" ", "").replace(":", "")
                for fp in data.get("signerFingerprints", [])]

    @property
    def version(self) -> str:
        return self.pin.get("version", "")

    def write_pin(self) -> None:
        self.pin_path.write_text(json.dumps(self.pin, indent=2, sort_keys=True) + "\n")


def current_system() -> str:
    machine = platform.machine().lower()
    os_name = "darwin" if platform.system() == "Darwin" else "linux"
    table = {
        "x86_64": "x86_64", "amd64": "x86_64",
        "aarch64": "aarch64", "arm64": "aarch64",
        "i686": "i686", "i386": "i686",
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


def compute_sri(app_id: str, version: str, source: str, arch: str, outdir: Path) -> str:
    """Download the APK and hash the layout the derivation will produce.

    fetchApk.nix installs into ``$out/share/apk/<original-name>``; the NAR hash
    of that layout only matches the download if we stage the identical tree.
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
        capture_output=True, text=True, timeout=CLI_TIMEOUT, check=True,
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
        capture_output=True, text=True, timeout=CLI_TIMEOUT,
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


def version_key(version: str) -> tuple:
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
    row = soup.find(attrs={"data-dt-version": True})
    if row:
        return row.get("data-dt-version")
    raise LookupError(f"could not determine latest version for {app_id}")


async def _apkpure_detail(base: str, app_id: str) -> str:
    async def _get(url: str) -> str:
        async with httpx.AsyncClient(headers=HEADERS, timeout=TIMEOUT) as client:
            resp = await client.get(url)
            resp.raise_for_status()
            return resp.text

    soup = BeautifulSoup(await _get(f"{base}/search?q={app_id}"), "html.parser")
    slug = None
    for a in soup.find_all("a", href=True):
        href = a["href"]
        if href.startswith("/") and href.endswith(f"/{app_id}"):
            slug = href.strip("/").rsplit("/", 1)[0]
            break
    if not slug:
        raise LookupError(f"no APKPure page found for {app_id}")

    try:
        return await _get(f"{base}/{slug}/{app_id}")
    except httpx.HTTPError:
        for fallback in APKPURE_BASES:
            if fallback == base:
                continue
            try:
                return await _get(f"{fallback}/{slug}/{app_id}")
            except httpx.HTTPError:
                continue
        raise


async def fetch_fdroid_index(repo_url: str) -> dict:
    """Fetch and parse a F-Droid-format ``index-v1.json``."""
    url = f"{repo_url.rstrip('/')}/index-v1.json"
    async with httpx.AsyncClient(headers=HEADERS, timeout=httpx.Timeout(120.0)) as client:
        resp = await client.get(url)
        resp.raise_for_status()
        return resp.json()


async def load_fdroid_indexes(pkgs: list[Package]) -> dict[str, dict | None]:
    """Fetch each distinct F-Droid-format index once (they are large)."""
    urls = sorted({p.repo_url for p in pkgs if p.source == "f-droid"})
    indexes: dict[str, dict | None] = {}
    for url in urls:
        try:
            indexes[url] = await fetch_fdroid_index(url)
        except (httpx.HTTPError, ValueError) as exc:
            log.warning("could not fetch f-droid index %s: %s", url, exc)
            indexes[url] = None
    return indexes


async def update_fdroid_package(pkg: Package, indexes: dict[str, dict | None]) -> str:
    """Update an f-droid app from its repo's signed index (no download)."""
    index = indexes.get(pkg.repo_url)
    if index is None:
        return f"[warn] {pkg.app_id}: f-droid index unavailable for {pkg.repo_url}"
    entries = index.get("packages", {}).get(pkg.app_id)
    if not entries:
        return f"[warn] {pkg.app_id}: not present in {pkg.repo_url} index"

    latest = max(entries, key=lambda e: e.get("versionCode", 0))
    version = latest.get("versionName", "")
    if not version:
        return f"[warn] {pkg.app_id}: index entry has no versionName"
    if not args.rehash and version == pkg.version:
        return f"[skip] {pkg.app_id}: already at {version}"

    sri = sha256_hex_to_sri(latest["hash"])
    new_pin = {"version": version, "apkName": latest["apkName"], "architectures": {}}
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


async def update_package(pkg: Package, semaphore: asyncio.Semaphore,
                          fdroid_indexes: dict[str, dict | None] | None = None) -> str:
    async with semaphore:
        if pkg.source not in VERSIONED_SOURCES and not args.rehash:
            return f"[skip] {pkg.app_id}: {pkg.source} cannot be auto-updated (use --rehash)"
        if pkg.source == "f-droid":
            return await update_fdroid_package(pkg, fdroid_indexes or {})

        try:
            latest = await get_latest_version(pkg.app_id, pkg.source)
        except (httpx.HTTPError, LookupError, subprocess.SubprocessError) as exc:
            return f"[warn] {pkg.app_id}: {exc}"

        version = latest if latest != pkg.version and not args.rehash else pkg.version
        if not args.rehash and not version:
            return f"[warn] {pkg.app_id}: no version known"

        hashes = {}
        ok = True
        downloaded = None
        for system, arch in requested_arch_pins(args.systems):
            try:
                with tempfile.TemporaryDirectory() as tmp:
                    sri, apk_path = await asyncio.to_thread(
                        compute_sri, pkg.app_id, version, pkg.source, arch, Path(tmp)
                    )
                    hashes[system] = sri
                    downloaded = downloaded or apk_path
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
        if expected and downloaded is not None and not args.skip_verify and _command_exists("apksigner"):
            found = await asyncio.to_thread(apksigner_fingerprints, downloaded)
            match = bool(set(found) & set(expected))
            verified = [f"{'ok' if match else 'MISMATCH'} signer {pkg.app_id}"]
            if not match:
                return f"[fail] {pkg.app_id}@{version}: signer cert mismatch ({found} not in {expected})"
        elif expected and not args.dry_run and not args.check and not args.skip_verify:
            log.warning(
                "not verifying signer for %s: apksigner not found or download not staged", pkg.app_id
            )

        if not hashes:
            return f"[warn] {pkg.app_id}: no architectures requested"

        new_pin = {"version": version, "architectures": {}}
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


def find_packages() -> list[Package]:
    pkgs = []
    for category in sorted(PKGS_DIR.iterdir()):
        if not category.is_dir():
            continue
        for app_dir in sorted(category.iterdir()):
            if (app_dir / "package.nix").exists():
                pkgs.append(Package(app_dir))
    return pkgs


async def main(cli: argparse.Namespace) -> None:
    pkgs = find_packages()
    if cli.only:
        pkgs = [p for p in pkgs if p.app_id == cli.only]
        if not pkgs:
            log.error("no package found for app id: %s", cli.only)
            sys.exit(1)

    for tool in ("apkeep", "nix"):
        if not _command_exists(tool):
            log.error("missing required tool: %s", tool)
            sys.exit(1)

    fdroid_indexes = await load_fdroid_indexes(pkgs)
    semaphore = asyncio.Semaphore(CONCURRENCY_LIMIT)
    results = await asyncio.gather(
        *(update_package(p, semaphore, fdroid_indexes) for p in pkgs)
    )
    for line in results:
        print(line)


def _command_exists(name: str) -> bool:
    return any(
        (Path(p) / name).is_file()
        for p in os.environ.get("PATH", "").split(os.pathsep)
        if p
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Update Android APK packages")
    parser.add_argument("--check", action="store_true", help="only report, never modify")
    parser.add_argument("--dry-run", action="store_true", help="compute hashes, don't write")
    parser.add_argument("--rehash", action="store_true",
                        help="recompute hashes for pinned versions (supports google-play/aurora)")
    parser.add_argument("--only", metavar="APP_ID", help="only update this app id")
    parser.add_argument("--systems", metavar="SYSTEM[=ABI]",
                        default=[f"{current_system()}=universal"], nargs="+",
                        help="how to pin architectures, e.g. x86_64-linux=universal, "
                             "aarch64-linux=arm64-v8a (default: current system, universal)")
    parser.add_argument("--skip-verify", action="store_true",
                        help="skip apksigner fingerprint verification (default: verify when apksigner exists)")
    return parser.parse_args()


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    args = parse_args()
    asyncio.run(main(args))