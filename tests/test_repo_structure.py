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
  * recommended.json (when curated) uses only known layers/keys/values
"""

import json
import re
from collections.abc import Iterator
from pathlib import Path

import pytest

import update

PKGS_DIR = update.PKGS_DIR
CATEGORIES = [
    "browser",
    "camera",
    "connectivity",
    "development",
    "education",
    "finance",
    "games",
    "graphics",
    "health",
    "keyboard",
    "maps",
    "messaging",
    "misc",
    "music",
    "productivity",
    "reading",
    "security",
    "social",
    "time",
    "tools",
    "video",
    "weather",
    "writing",
]

# SRI form of a sha256: base64 of 32 bytes (44 chars, ends with '=').
SRI_HASH_RE = re.compile(r"^sha256-[A-Za-z0-9+/]{43}=$")


def iter_app_dirs() -> Iterator[tuple[str, Path]]:
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
    for _cat, app_dir in iter_app_dirs():
        for fname in ("package.nix", "hashes.json"):
            if not (app_dir / fname).is_file():
                missing.append(f"{app_dir.relative_to(PKGS_DIR)}: missing {fname}")
    assert not missing, "\n".join(missing)


def test_hashes_json_schema():
    bad = []
    for _cat, app_dir in iter_app_dirs():
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
                bad.append(
                    f"{app_dir.name}: architectures[{system}] hash looks wrong: {entry.get('hash')!r}"
                )
            if "archStr" in entry and not isinstance(entry["archStr"], str):
                bad.append(f"{app_dir.name}: architectures[{system}] archStr not a string")
    assert not bad, "\n".join(bad)


def test_pinned_apps_have_hashes_unpinned_are_empty():
    bad = []
    for _cat, app_dir in iter_app_dirs():
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


def _seeded_apps() -> set[str]:
    out: set[str] = set()
    for _cat, app_dir in iter_app_dirs():
        if (app_dir / "verified.json").exists():
            out.add(app_dir.name)
    return out


def test_verified_json_schema():
    bad = []
    for _cat, app_dir in iter_app_dirs():
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
        if not isinstance(fps, list) or not all(isinstance(f, str) and f for f in fps):
            bad.append(f"{app_dir.name}: signerFingerprints must be a list of strings")
        elif not fps and not any(
            s in data.get("source", "") for s in ("APKPure", "GitHub releases")
        ):
            # APKPure and GitHub releases publish no signer database, so their
            # seeds legitimately start empty (update.py records fingerprints
            # after the first verified download); every other source must know
            # its signer.
            bad.append(f"{app_dir.name}: empty signerFingerprints with non-APKPure/GitHub source")
        if not data.get("source"):
            bad.append(f"{app_dir.name}: verified.json missing attribution (source)")
    assert not bad, "\n".join(bad)


def test_history_json_schema():
    bad = []
    for _cat, app_dir in iter_app_dirs():
        hpath = app_dir / "history.json"
        if not hpath.exists():
            continue
        try:
            data = json.loads(hpath.read_text())
        except json.JSONDecodeError as exc:
            bad.append(f"{app_dir.name}: invalid history.json: {exc}")
            continue
        versions = data.get("versions")
        if not isinstance(versions, list):
            bad.append(f"{app_dir.name}: history.json missing 'versions' list")
            continue
        for i, v in enumerate(versions):
            if not isinstance(v, dict) or not isinstance(v.get("version"), str) or not v["version"]:
                bad.append(f"{app_dir.name}: versions[{i}] missing non-empty 'version' string")
            if "versionCode" in v and not isinstance(v["versionCode"], int):
                bad.append(f"{app_dir.name}: versions[{i}] versionCode must be an int")
    assert not bad, "\n".join(bad)


def test_package_nix_reads_hashes_json():
    bad = []
    for _cat, app_dir in iter_app_dirs():
        text = (app_dir / "package.nix").read_text()
        if "hashes.json" not in text:
            bad.append(f"{app_dir.name}: package.nix does not read ./hashes.json")
        if "fetchApk" not in text:
            bad.append(f"{app_dir.name}: package.nix does not call fetchApk")
    assert not bad, "\n".join(bad)


def test_fdroid_apps_carry_apkname_and_flat_hash():
    bad = []
    for _cat, app_dir in iter_app_dirs():
        text = (app_dir / "package.nix").read_text()
        if 'source = "f-droid"' not in text:
            continue
        pin = json.loads((app_dir / "hashes.json").read_text())
        if not pin.get("apkName"):
            bad.append(f"{app_dir.name}: f-droid app missing apkName in hashes.json")
        if not pin.get("version"):
            bad.append(f"{app_dir.name}: f-droid app must be fully pinned (no empty version)")
        for _system, entry in pin.get("architectures", {}).items():
            if not SRI_HASH_RE.match(entry.get("hash", "")):
                bad.append(
                    f"{app_dir.name}: f-droid hash must be a flat sha256 SRI, got {entry.get('hash')!r}"
                )
        vpath = app_dir / "verified.json"
        if not vpath.exists():
            bad.append(f"{app_dir.name}: f-droid app missing verified.json")
    assert not bad, "\n".join(bad)


def test_category_dirs_are_known():
    for _cat, app_dir in iter_app_dirs():
        assert app_dir.parent.name in CATEGORIES, f"unknown category dir: {app_dir.parent.name}"


RECOMMENDED_KEYS = {"permissions", "appops", "notifications", "links"}
PERMISSION_ACTIONS = {"allow", "deny"}
APPOP_MODES = {"allow", "deny", "ignore", "foreground", "default"}
NOTIFICATION_KEYS = {"enabled", "listeners", "dnd", "bubbles"}
BUBBLES = {"none", "all", "selected"}
LINK_KEYS = {"open", "domains"}


def test_recommended_json_schema():
    """The curated block for `recommended` mode must be well-formed.

    It is user-facing config data, not a pin: a typo here would silently be a
    no-op on a phone, so every key and value is checked.
    """
    bad: list[str] = []
    for app_id, app_dir in iter_app_dirs():
        sidecar = app_dir / "recommended.json"
        if not sidecar.exists():
            continue
        try:
            block = json.loads(sidecar.read_text())
        except json.JSONDecodeError as exc:
            bad.append(f"{app_id}: invalid recommended.json: {exc}")
            continue
        if not isinstance(block, dict):
            bad.append(f"{app_id}: recommended.json must be an object")
            continue
        unknown = set(block) - RECOMMENDED_KEYS
        if unknown:
            bad.append(f"{app_id}: unknown keys {sorted(unknown)}")

        permissions = block.get("permissions") or {}
        if not isinstance(permissions, dict):
            bad.append(f"{app_id}: permissions must be an object")
        else:
            for permission, action in permissions.items():
                if "." not in permission:
                    bad.append(f"{app_id}: {permission!r} is not a permission name")
                if action not in PERMISSION_ACTIONS:
                    bad.append(f"{app_id}: permission {permission} has action {action!r}")

        appops = block.get("appops") or {}
        if not isinstance(appops, dict):
            bad.append(f"{app_id}: appops must be an object")
        else:
            for op, mode in appops.items():
                if not re.fullmatch(r"[A-Z0-9_]+", op):
                    bad.append(f"{app_id}: {op!r} is not an app-op name")
                if mode not in APPOP_MODES:
                    bad.append(f"{app_id}: app op {op} has mode {mode!r}")

        notifications = block.get("notifications") or {}
        if not isinstance(notifications, dict):
            bad.append(f"{app_id}: notifications must be an object")
        else:
            unknown = set(notifications) - NOTIFICATION_KEYS
            if unknown:
                bad.append(f"{app_id}: unknown notification keys {sorted(unknown)}")
            if not isinstance(notifications.get("enabled", True), bool):
                bad.append(f"{app_id}: notifications.enabled must be a boolean")
            if not isinstance(notifications.get("dnd", True), bool):
                bad.append(f"{app_id}: notifications.dnd must be a boolean")
            bubbles = notifications.get("bubbles")
            if bubbles is not None and bubbles not in BUBBLES:
                bad.append(f"{app_id}: notifications.bubbles {bubbles!r} is not none|all|selected")
            listeners = notifications.get("listeners")
            if listeners is not None:
                if not isinstance(listeners, list):
                    bad.append(f"{app_id}: notifications.listeners must be a list")
                else:
                    for component in listeners:
                        if "/" not in str(component):
                            bad.append(f"{app_id}: listener {component!r} is not package/component")

        links = block.get("links") or {}
        if not isinstance(links, dict):
            bad.append(f"{app_id}: links must be an object")
        else:
            unknown = set(links) - LINK_KEYS
            if unknown:
                bad.append(f"{app_id}: unknown link keys {sorted(unknown)}")
            if "open" in links and not isinstance(links["open"], bool):
                bad.append(f"{app_id}: links.open must be a boolean")
            for domain, action in (links.get("domains") or {}).items():
                if "." not in domain:
                    bad.append(f"{app_id}: {domain!r} is not a domain")
                if action not in PERMISSION_ACTIONS:
                    bad.append(f"{app_id}: link domain {domain} has action {action!r}")
    assert not bad, "\n".join(bad)
