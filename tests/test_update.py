"""Unit tests for scripts/update.py helpers.

Everything here is offline: subprocess/httpx calls are mocked or avoided.
"""

import asyncio
import base64
import json
import subprocess
from pathlib import Path
from types import SimpleNamespace

import pytest

import update


# ---------------------------------------------------------------- pure helpers

def test_version_key_orders_correctly():
    assert update.version_key("1.2.3") > update.version_key("1.2")
    assert update.version_key("1.10") > update.version_key("1.9")
    assert update.version_key("0.118.0") > update.version_key("0.99.9")
    assert update.version_key("2.0-rc0") < update.version_key("2.0")


def test_requested_arch_pins_default_universal():
    assert update.requested_arch_pins(["x86_64-linux"]) == [("x86_64-linux", "universal")]
    assert update.requested_arch_pins(["aarch64-linux=arm64-v8a"]) == [("aarch64-linux", "arm64-v8a")]
    assert update.requested_arch_pins(["a=universal", "b=arm64-v8a"]) == [("a", "universal"), ("b", "arm64-v8a")]


def test_normalize_sha256():
    assert update._normalize_sha256("aa:bb: cc") == "AABBCC"
    assert update._normalize_sha256(" 12 34 ") == "1234"


def test_sha256_hex_to_sri():
    # sha256 of empty-ish known value: hex -> SRI round trip
    digest = bytes(range(32))
    hexstr = digest.hex()
    expected = "sha256-" + base64.b64encode(digest).decode()
    assert update.sha256_hex_to_sri(hexstr) == expected


# --------------------------------------------------------------- apkeep argv

def test_build_apkeep_cmd_apkpure_versioned_universal(tmp_path):
    cmd = update.build_apkeep_cmd("com.spotify.music", "9.1.72.1891", "apk-pure", "universal", tmp_path)
    assert cmd == ["apkeep", "-a", "com.spotify.music@9.1.72.1891", "-d", "apk-pure", str(tmp_path)]


def test_build_apkeep_cmd_arch_option():
    cmd = update.build_apkeep_cmd("org.app", "1.0", "apk-pure", "arm64-v8a", Path("/out"))
    assert "-o" in cmd and "arch=arm64-v8a" in cmd


def test_build_apkeep_cmd_uses_normalized_source():
    # build_apkeep_cmd receives already-normalized sources from Package;
    # alias normalization happens at the Package level.
    assert update.build_apkeep_cmd("a", "1", "apk-pure", "universal", Path("/o"))[4] == "apk-pure"
    assert update.build_apkeep_cmd("a", "1", "google-play", "universal", Path("/o"))[4] == "google-play"


def test_build_apkeep_cmd_google_creds(monkeypatch):
    monkeypatch.setenv("GOOGLE_EMAIL", "me@example.com")
    monkeypatch.setenv("GOOGLE_AUTH_TOKEN", "ya29.secret")
    monkeypatch.setenv("GOOGLE_ACCEPT_TOS", "1")
    cmd = update.build_apkeep_cmd("com.app", "1.0", "google-play", "universal", Path("/o"))
    joined = " ".join(cmd)
    assert "-e me@example.com" in joined
    assert "--auth-token ya29.secret" in joined
    assert "--accept-tos" in joined


def test_build_apkeep_cmd_source_options_env(monkeypatch):
    monkeypatch.setenv("SOURCE_OPTIONS", "tier=1,split_apk=true")
    cmd = update.build_apkeep_cmd("a", "1", "apk-pure", "universal", Path("/o"))
    assert "-o" in cmd and "tier=1,split_apk=true" in cmd


# ------------------------------------------------------------------ Package

def _write_package(tmp_path: Path, app_id: str, source: str | None = None, repo_url: str | None = None) -> Path:
    d = tmp_path / app_id
    d.mkdir(parents=True)
    lines = ["{ fetchApk }:", "", "let", "  pin = builtins.fromJSON (builtins.readFile ./hashes.json);", "in", "fetchApk {"]
    lines.append(f'  pname = "app";')
    lines.append(f'  appId = "{app_id}";')
    if source:
        lines.append(f'  source = "{source}";')
    if repo_url:
        lines.append(f'  repoUrl = "{repo_url}";')
    lines += ["  version = pin.version;", "  archs = pin.architectures;", "}"]
    (d / "package.nix").write_text("\n".join(lines) + "\n")
    return d


def test_package_source_defaults_to_apkpure(tmp_path):
    d = _write_package(tmp_path, "com.example.app")
    assert update.Package(d).source == "apk-pure"


def test_package_source_detection_and_aliases(tmp_path):
    assert update.Package(_write_package(tmp_path, "a.aurora", "aurora")).source == "google-play"
    assert update.Package(_write_package(tmp_path, "a.fdroid", "f-droid")).source == "f-droid"


def test_package_repo_url(tmp_path):
    assert update.Package(_write_package(tmp_path, "a.fdroid1", "f-droid")).repo_url == "https://f-droid.org/repo"
    custom = update.Package(_write_package(tmp_path, "a.fdroid2", "f-droid", "https://apt.izzysoft.de/fdroid/repo"))
    assert custom.repo_url == "https://apt.izzysoft.de/fdroid/repo"


def test_package_load_pin_and_corrupt_json(tmp_path):
    d = _write_package(tmp_path, "a.b")
    (d / "hashes.json").write_text("{not json")
    pkg = update.Package(d)
    assert pkg.pin == {"version": "", "architectures": {}}
    assert pkg.version == ""


def test_package_verified_fingerprints_normalized(tmp_path):
    d = _write_package(tmp_path, "a.b")
    (d / "verified.json").write_text(json.dumps({
        "package": "a.b",
        "signerFingerprints": ["58:1D:49:7A", "aa:bb:cc"],
    }))
    pkg = update.Package(d)
    assert pkg.verified_fingerprints == ["581D497A", "AABBCC"]


# --------------------------------------------------------- apksigner parsing

def test_apksigner_fingerprints_parses_output(monkeypatch, tmp_path):
    apk = tmp_path / "app.apk"
    apk.write_bytes(b"x")
    fake = subprocess.CompletedProcess([], 0, stdout=(
        "Signer #1 certificate DN: CN=App\n"
        "Certificate SHA-256 digest: 1e:2f:3a:4b:5c:6d:7e:8f\n"
        "Certificate SHA-256 fingerprint: 9a:8b:7c:6d:5e:4f:3a:2b\n"
    ), stderr="")
    monkeypatch.setattr(update.subprocess, "run", lambda *a, **k: fake)
    # the parser collects every SHA-256 digest/fingerprint line it sees
    assert update.apksigner_fingerprints(apk) == ["1E2F3A4B5C6D7E8F", "9A8B7C6D5E4F3A2B"]


def test_apksigner_fingerprints_raises_when_none(monkeypatch, tmp_path):
    apk = tmp_path / "app.apk"
    apk.write_bytes(b"x")
    fake = subprocess.CompletedProcess([], 0, stdout="no certs here", stderr="")
    monkeypatch.setattr(update.subprocess, "run", lambda *a, **k: fake)
    with pytest.raises(LookupError):
        update.apksigner_fingerprints(apk)


# ------------------------------------------------------------- compute_sri

def test_compute_sri_stages_layout_and_hashes_recursive(monkeypatch, tmp_path):
    calls = {}

    def fake_run(cmd, **kwargs):
        calls["apkeep"] = cmd
        (tmp_path / "raw" / "app_123.apk").write_bytes(b"fake apk bytes")
        return subprocess.CompletedProcess([], 0, stdout="", stderr="")

    def fake_check_output(cmd, **kwargs):
        calls["nix"] = cmd
        return "sha256-fakehash\n"  # text=True is used by compute_sri

    monkeypatch.setattr(update.subprocess, "run", fake_run)
    monkeypatch.setattr(update.subprocess, "check_output", fake_check_output)

    sri, apk = update.compute_sri("com.app", "1.2.3", "apk-pure", "universal", tmp_path)
    assert sri == "sha256-fakehash"
    assert apk.name == "app_123.apk"
    # apkeep ran with version pin; nix hashed the staged share/apk tree (recursive)
    assert "com.app@1.2.3" in " ".join(calls["apkeep"])
    assert calls["nix"][:5] == ["nix", "hash", "path", "--type", "sha256"]
    assert "--flat" not in calls["nix"]
    assert (tmp_path / "staged" / "share" / "apk" / "app_123.apk").exists()


def test_compute_sri_raises_when_no_apk(monkeypatch, tmp_path):
    monkeypatch.setattr(update.subprocess, "run", lambda *a, **k: None)
    with pytest.raises(FileNotFoundError):
        update.compute_sri("com.app", "1.2.3", "apk-pure", "universal", tmp_path)


# ----------------------------------------------------- f-droid update path

def test_update_fdroid_package_writes_pin_from_index(monkeypatch, tmp_path):
    d = _write_package(tmp_path, "de.jepfa.hyle_x", "f-droid")
    (d / "hashes.json").write_text(json.dumps({"version": "", "architectures": {}}))
    pkg = update.Package(d)

    index = {
        "packages": {
            "de.jepfa.hyle_x": [
                {"versionName": "1.0.0", "versionCode": 100, "apkName": "hyle_100.apk",
                 "hash": "aa" * 32, "nativecode": []},
                {"versionName": "1.1.0", "versionCode": 110, "apkName": "hyle_110.apk",
                 "hash": "bb" * 32, "nativecode": []},
            ]
        }
    }
    update.args = SimpleNamespace(rehash=False, systems=["x86_64-linux=universal"], dry_run=False, check=False, skip_verify=True)

    line = asyncio.run(update.update_fdroid_package(pkg, {"https://f-droid.org/repo": index}))
    assert "[upd]" in line and "1.1.0" in line
    pin = json.loads((d / "hashes.json").read_text())
    assert pin["version"] == "1.1.0"
    assert pin["apkName"] == "hyle_110.apk"
    assert pin["architectures"]["x86_64-linux"]["hash"] == "sha256-" + base64.b64encode(bytes.fromhex("bb" * 32)).decode()


def test_update_fdroid_package_skips_when_unchanged(monkeypatch, tmp_path):
    d = _write_package(tmp_path, "a.b", "f-droid")
    sri = "sha256-" + base64.b64encode(bytes(range(32))).decode()
    (d / "hashes.json").write_text(json.dumps({
        "version": "1.1.0", "apkName": "a_110.apk",
        "architectures": {"x86_64-linux": {"archStr": "universal", "hash": sri}},
    }))
    pkg = update.Package(d)
    index = {"packages": {"a.b": [{"versionName": "1.1.0", "versionCode": 110, "apkName": "a_110.apk", "hash": "aa" * 32}]}}
    update.args = SimpleNamespace(rehash=False, systems=["x86_64-linux=universal"], dry_run=False, check=False, skip_verify=True)
    line = asyncio.run(update.update_fdroid_package(pkg, {"https://f-droid.org/repo": index}))
    assert "[skip]" in line
    # pin untouched
    assert json.loads((d / "hashes.json").read_text())["version"] == "1.1.0"


def test_update_fdroid_package_respects_its_own_repo(monkeypatch, tmp_path):
    # The same app id exists on f-droid.org and IzzyOnDroid with DIFFERENT
    # hashes. A package pinned to Izzy must update against Izzy's index only.
    d = _write_package(tmp_path, "com.example.app", "f-droid", "https://apt.izzysoft.de/fdroid/repo")
    (d / "hashes.json").write_text(json.dumps({"version": "", "architectures": {}}))
    pkg = update.Package(d)

    fdroid_index = {"packages": {"com.example.app": [{"versionName": "9.9.9", "versionCode": 999, "apkName": "x.apk", "hash": "11" * 32}]}}
    izzy_index = {"packages": {"com.example.app": [{"versionName": "1.2.3", "versionCode": 123, "apkName": "y.apk", "hash": "22" * 32}]}}
    indexes = {
        "https://f-droid.org/repo": fdroid_index,
        "https://apt.izzysoft.de/fdroid/repo": izzy_index,
    }
    update.args = SimpleNamespace(rehash=False, systems=["x86_64-linux=universal"], dry_run=False, check=False, skip_verify=True)
    line = asyncio.run(update.update_fdroid_package(pkg, indexes))
    pin = json.loads((d / "hashes.json").read_text())
    assert pin["version"] == "1.2.3"  # from Izzy, not 9.9.9 from f-droid.org
    assert pin["apkName"] == "y.apk"
    assert pin["architectures"]["x86_64-linux"]["hash"] == "sha256-" + base64.b64encode(bytes.fromhex("22" * 32)).decode()
    assert "[upd]" in line


def test_update_fdroid_package_not_in_index(tmp_path):
    d = _write_package(tmp_path, "a.b", "f-droid")
    (d / "hashes.json").write_text(json.dumps({"version": "", "architectures": {}}))
    pkg = update.Package(d)
    update.args = SimpleNamespace(rehash=False, systems=["x86_64-linux"], dry_run=False, check=False, skip_verify=True)
    line = asyncio.run(update.update_fdroid_package(pkg, {"https://f-droid.org/repo": {"packages": {}}}))
    assert "[warn]" in line


def test_update_fdroid_package_stamps_new_hash_on_all_systems(monkeypatch, tmp_path):
    # A version bump changes the flat hash for EVERY system (the same APK file
    # serves all Nix systems) - stale preserved hashes would break builds.
    d = _write_package(tmp_path, "a.b", "f-droid")
    (d / "hashes.json").write_text(json.dumps({
        "version": "1.0.0", "apkName": "a_100.apk",
        "architectures": {
            "x86_64-linux": {"archStr": "universal", "hash": "sha256-old"},
            "aarch64-linux": {"archStr": "universal", "hash": "sha256-old"},
        },
    }))
    pkg = update.Package(d)
    index = {"packages": {"a.b": [{"versionName": "2.0.0", "versionCode": 200, "apkName": "a_200.apk", "hash": "cc" * 32}]}}
    update.args = SimpleNamespace(rehash=False, systems=["x86_64-linux=universal"], dry_run=False, check=False, skip_verify=True)
    asyncio.run(update.update_fdroid_package(pkg, {"https://f-droid.org/repo": index}))
    pin = json.loads((d / "hashes.json").read_text())
    expected = "sha256-" + base64.b64encode(bytes.fromhex("cc" * 32)).decode()
    assert set(pin["architectures"]) == {"x86_64-linux", "aarch64-linux"}
    assert pin["architectures"]["x86_64-linux"]["hash"] == expected
    assert pin["architectures"]["aarch64-linux"]["hash"] == expected
    assert pin["apkName"] == "a_200.apk"


def test_update_package_handles_download_timeout_gracefully(monkeypatch, tmp_path):
    # A slow/flaky apkeep download must degrade that one package to [fail],
    # not abort the whole update run (TimeoutExpired is a SubprocessError).
    d = _write_package(tmp_path, "com.example.app")
    (d / "hashes.json").write_text(json.dumps({"version": "1.0.0", "architectures": {}}))
    pkg = update.Package(d)
    update.args = SimpleNamespace(rehash=False, systems=["x86_64-linux=universal"],
                                  dry_run=False, check=False, skip_verify=True)

    async def fake_latest(app_id, source):
        return "1.0.0"

    def fake_compute(*a, **k):
        raise subprocess.TimeoutExpired(cmd=["apkeep"], timeout=120)

    monkeypatch.setattr(update, "get_latest_version", fake_latest)
    monkeypatch.setattr(update, "compute_sri", fake_compute)
    line = asyncio.run(update.update_package(pkg, asyncio.Semaphore(1)))
    assert line.startswith("[fail]")
    assert "timed out" in line


# ------------------------------------------------------------- latest version

def test_get_latest_version_falls_back_to_apkpure_page(monkeypatch):
    async def fake_detail(base, app_id):
        return '<html><div data-dt-version="3.2.1"></div></html>'
    monkeypatch.setattr(update, "_apkpure_detail", fake_detail)
    assert asyncio.run(update.get_latest_version("com.app", "apk-pure")) == "3.2.1"
