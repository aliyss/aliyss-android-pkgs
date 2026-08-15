"""Structural invariants of the `pkgs/` tree.

These tests walk the real repository (or the copy of it that the Nix `checks`
derivation stages) and assert that every app directory is well-formed. They
are the guard rails that keep the repo healthy as it grows to thousands of
apps:

  * every app dir has package.nix + hashes.json (+ verified.json when seeded)
  * hashes.json follows the {version, architectures} pin schema
  * pinned apps have a real version and at least one hash; seeded-but-unpinned
    apps carry an empty pin (and are excluded from the package set by
    pkgs/default.nix)
  * verified.json is valid and carries the signer fingerprints
  * f-droid apps additionally carry apkName and a flat (file) hash
"""

import json
import re

import pytest

import update

PKGS_DIR = update.PKGS_DIR
CATEGORIES = ["browser", "camera", "connectivity", "development", "education",
              "finance", "games", "graphics", "health", "keyboard", "maps",
              "messaging", "misc", "music", "productivity", "reading", "security",
              "social", "time", "tools", "video", "weather", "writing"]

# SRI form of a sha256: base64 of 32 bytes (44 chars, ends with '=').
SRI_HASH_RE = re.compile(r"^sha256-[A-Za-z0-9+/]{43}=$")


def iter_app_dirs():
    if not PKGS_DIR.is_dir():
        pytest.skip(f"pkgs dir not present: {PKGS_DIR}")
    for category in sorted(PKGS_DIR.iterdir()):
        if not category.is_dir():
            continue
        for app_dir in sorted(category.iterdir()):
            if app_dir.is_dir():
                yield category.name, app_dir


def test_pkgs_dir_exists():
    assert PKGS_DIR.is_dir(), f"expected pkgs dir at {PKGS_DIR}"


def test_all_app_dirs_have_required_files():
    missing = []
    for cat, app_dir in iter_app_dirs():
        for fname in ("package.nix", "hashes.json"):
            if not (app_dir / fname).is_file():
                missing.append(f"{app_dir.relative_to(PKGS_DIR)}: missing {fname}")
    assert not missing, "\n".join(missing)


def test_hashes_json_schema():
    bad = []
    for cat, app_dir in iter_app_dirs():
        try:
            pin = json.loads((app_dir / "hashes.json").read_text())
        except json.JSONDecodeError as exc:
            bad.append(f"{app_dir.name}: invalid JSON: {exc}")
            continue
        if not isinstance(pin, dict):
            bad.append(f"{app_dir.name}: pin is not an object")
            continue
        if "version" not in pin or "architectures" not in pin:
            bad.append(f"{app_dir.name}: missing version/architectures keys")
            continue
        if not isinstance(pin["version"], str):
            bad.append(f"{app_dir.name}: version is not a string")
        if not isinstance(pin["architectures"], dict):
            bad.append(f"{app_dir.name}: architectures is not an object")
            continue
        for system, entry in pin["architectures"].items():
            if not isinstance(entry, dict) or "hash" not in entry:
                bad.append(f"{app_dir.name}: architectures[{system}] missing hash")
            elif not SRI_HASH_RE.match(entry["hash"]):
                bad.append(f"{app_dir.name}: architectures[{system}] hash looks wrong: {entry.get('hash')!r}")
            if "archStr" in entry and not isinstance(entry["archStr"], str):
                bad.append(f"{app_dir.name}: architectures[{system}] archStr not a string")
    assert not bad, "\n".join(bad)


def test_pinned_apps_have_hashes_unpinned_are_empty():
    bad = []
    for cat, app_dir in iter_app_dirs():
        pin = json.loads((app_dir / "hashes.json").read_text())
        version = pin.get("version", "")
        if version:
            if not pin.get("architectures"):
                bad.append(f"{app_dir.name}: pinned version {version!r} but no hashes")
        else:
            if pin.get("architectures"):
                bad.append(f"{app_dir.name}: empty version but has hashes")
            if app_dir.name not in _seeded_apps():
                bad.append(f"{app_dir.name}: unpinned app without verified.json?")
    assert not bad, "\n".join(bad)


def _seeded_apps():
    out = set()
    for cat, app_dir in iter_app_dirs():
        if (app_dir / "verified.json").exists():
            out.add(app_dir.name)
    return out


def test_verified_json_schema():
    bad = []
    for cat, app_dir in iter_app_dirs():
        vpath = app_dir / "verified.json"
        if not vpath.exists():
            continue
        try:
            data = json.loads(vpath.read_text())
        except json.JSONDecodeError as exc:
            bad.append(f"{app_dir.name}: invalid verified.json: {exc}")
            continue
        if data.get("package") != app_dir.name:
            bad.append(f"{app_dir.name}: verified.json package != dir name")
        fps = data.get("signerFingerprints")
        if not isinstance(fps, list) or not fps or not all(isinstance(f, str) and f for f in fps):
            bad.append(f"{app_dir.name}: signerFingerprints must be a non-empty list of strings")
        if not data.get("source"):
            bad.append(f"{app_dir.name}: verified.json missing attribution (source)")
    assert not bad, "\n".join(bad)


def test_package_nix_reads_hashes_json():
    bad = []
    for cat, app_dir in iter_app_dirs():
        text = (app_dir / "package.nix").read_text()
        if "hashes.json" not in text:
            bad.append(f"{app_dir.name}: package.nix does not read ./hashes.json")
        if "fetchApk" not in text:
            bad.append(f"{app_dir.name}: package.nix does not call fetchApk")
    assert not bad, "\n".join(bad)


def test_fdroid_apps_carry_apkname_and_flat_hash():
    bad = []
    for cat, app_dir in iter_app_dirs():
        text = (app_dir / "package.nix").read_text()
        if 'source = "f-droid"' not in text:
            continue
        pin = json.loads((app_dir / "hashes.json").read_text())
        if not pin.get("apkName"):
            bad.append(f"{app_dir.name}: f-droid app missing apkName in hashes.json")
        if not pin.get("version"):
            bad.append(f"{app_dir.name}: f-droid app must be fully pinned (no empty version)")
        for system, entry in pin.get("architectures", {}).items():
            if not SRI_HASH_RE.match(entry.get("hash", "")):
                bad.append(f"{app_dir.name}: f-droid hash must be a flat sha256 SRI, got {entry.get('hash')!r}")
        vpath = app_dir / "verified.json"
        if not vpath.exists():
            bad.append(f"{app_dir.name}: f-droid app missing verified.json")
    assert not bad, "\n".join(bad)


def test_category_dirs_are_known():
    for cat, app_dir in iter_app_dirs():
        assert cat in CATEGORIES, f"unknown category dir: {cat}"
