"""Unit tests for scripts/update.py helpers.

Everything here is offline: subprocess/httpx calls are mocked or avoided.
"""

import argparse
import asyncio
import base64
import inspect
import json
import subprocess
from pathlib import Path
from typing import Any
from collections.abc import Callable

import httpx
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
    assert update.requested_arch_pins(["aarch64-linux=arm64-v8a"]) == [
        ("aarch64-linux", "arm64-v8a")
    ]
    assert update.requested_arch_pins(["a=universal", "b=arm64-v8a"]) == [
        ("a", "universal"),
        ("b", "arm64-v8a"),
    ]


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
    cmd = update.build_apkeep_cmd(
        "com.spotify.music", "9.1.72.1891", "apk-pure", "universal", tmp_path
    )
    assert cmd == ["apkeep", "-a", "com.spotify.music@9.1.72.1891", "-d", "apk-pure", str(tmp_path)]


def test_build_apkeep_cmd_arch_option():
    cmd = update.build_apkeep_cmd("org.app", "1.0", "apk-pure", "arm64-v8a", Path("/out"))
    assert "-o" in cmd and "arch=arm64-v8a" in cmd


def test_build_apkeep_cmd_uses_normalized_source():
    # build_apkeep_cmd receives already-normalized sources from Package;
    # alias normalization happens at the Package level.
    assert update.build_apkeep_cmd("a", "1", "apk-pure", "universal", Path("/o"))[4] == "apk-pure"
    assert (
        update.build_apkeep_cmd("a", "1", "google-play", "universal", Path("/o"))[4]
        == "google-play"
    )


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


def _write_package(
    tmp_path: Path,
    app_id: str,
    source: str | None = None,
    repo_url: str | None = None,
    gh_repo: str | None = None,
) -> Path:
    d = tmp_path / app_id
    d.mkdir(parents=True)
    lines = [
        "{ fetchApk }:",
        "",
        "let",
        "  pin = builtins.fromJSON (builtins.readFile ./hashes.json);",
        "in",
        "fetchApk {",
    ]
    lines.append('  pname = "app";')
    lines.append(f'  appId = "{app_id}";')
    if source:
        lines.append(f'  source = "{source}";')
    if repo_url:
        lines.append(f'  repoUrl = "{repo_url}";')
    if gh_repo:
        lines.append(f'  ghRepo = "{gh_repo}";')
    lines += ["  version = pin.version;", "  archs = pin.architectures;", "}"]
    (d / "package.nix").write_text("\n".join(lines) + "\n")
    return d


def test_package_source_defaults_to_apkpure(tmp_path):
    d = _write_package(tmp_path, "com.example.app")
    assert update.Package(d).source == "apk-pure"


def test_package_source_detection_and_aliases(tmp_path):
    assert update.Package(_write_package(tmp_path, "a.aurora", "aurora")).source == "google-play"
    assert update.Package(_write_package(tmp_path, "a.fdroid", "f-droid")).source == "f-droid"
    assert (
        update.Package(_write_package(tmp_path, "a.github", "github")).source == "github-releases"
    )
    assert (
        update.Package(_write_package(tmp_path, "a.ghrel", "github-releases")).source
        == "github-releases"
    )


def test_package_gh_repo(tmp_path):
    pkg = update.Package(_write_package(tmp_path, "a.gh", "github-releases", gh_repo="o/r"))
    assert pkg.gh_repo == "o/r"
    assert update.Package(_write_package(tmp_path, "a.apk", "apk-pure")).gh_repo is None


def test_package_repo_url(tmp_path):
    assert (
        update.Package(_write_package(tmp_path, "a.fdroid1", "f-droid")).repo_url
        == "https://f-droid.org/repo"
    )
    custom = update.Package(
        _write_package(tmp_path, "a.fdroid2", "f-droid", "https://apt.izzysoft.de/fdroid/repo")
    )
    assert custom.repo_url == "https://apt.izzysoft.de/fdroid/repo"


def test_package_load_pin_and_corrupt_json(tmp_path):
    d = _write_package(tmp_path, "a.b")
    (d / "hashes.json").write_text("{not json")
    pkg = update.Package(d)
    assert pkg.pin == {"version": "", "architectures": {}}
    assert pkg.version == ""


def test_package_verified_fingerprints_normalized(tmp_path):
    d = _write_package(tmp_path, "a.b")
    (d / "verified.json").write_text(
        json.dumps(
            {
                "package": "a.b",
                "signerFingerprints": ["58:1D:49:7A", "aa:bb:cc"],
            }
        )
    )
    pkg = update.Package(d)
    assert pkg.verified_fingerprints == ["581D497A", "AABBCC"]


# --------------------------------------------------------- apksigner parsing


def test_apksigner_fingerprints_parses_output(monkeypatch, tmp_path):
    apk = tmp_path / "app.apk"
    apk.write_bytes(b"x")
    fake = subprocess.CompletedProcess(
        [],
        0,
        stdout=(
            "Signer #1 certificate DN: CN=App\n"
            "Certificate SHA-256 digest: 1e:2f:3a:4b:5c:6d:7e:8f\n"
            "Certificate SHA-256 fingerprint: 9a:8b:7c:6d:5e:4f:3a:2b\n"
        ),
        stderr="",
    )
    monkeypatch.setattr(subprocess, "run", lambda *a, **k: fake)
    # the parser collects every SHA-256 digest/fingerprint line it sees
    assert update.apksigner_fingerprints(apk) == ["1E2F3A4B5C6D7E8F", "9A8B7C6D5E4F3A2B"]


def test_apksigner_fingerprints_raises_when_none(monkeypatch, tmp_path):
    apk = tmp_path / "app.apk"
    apk.write_bytes(b"x")
    fake = subprocess.CompletedProcess([], 0, stdout="no certs here", stderr="")
    monkeypatch.setattr(subprocess, "run", lambda *a, **k: fake)
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

    monkeypatch.setattr(subprocess, "run", fake_run)
    monkeypatch.setattr(subprocess, "check_output", fake_check_output)

    sri, apk = update.compute_sri("com.app", "1.2.3", "apk-pure", "universal", tmp_path)
    assert sri == "sha256-fakehash"
    assert apk.name == "app_123.apk"
    # apkeep ran with version pin; nix hashed the staged share/apk tree (recursive)
    assert "com.app@1.2.3" in " ".join(calls["apkeep"])
    assert calls["nix"][:5] == ["nix", "hash", "path", "--type", "sha256"]
    assert "--flat" not in calls["nix"]
    assert (tmp_path / "staged" / "share" / "apk" / "app_123.apk").exists()


def test_compute_sri_raises_when_no_apk(monkeypatch, tmp_path):
    monkeypatch.setattr(subprocess, "run", lambda *a, **k: None)
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
                {
                    "versionName": "1.0.0",
                    "versionCode": 100,
                    "apkName": "hyle_100.apk",
                    "hash": "aa" * 32,
                    "nativecode": [],
                },
                {
                    "versionName": "1.1.0",
                    "versionCode": 110,
                    "apkName": "hyle_110.apk",
                    "hash": "bb" * 32,
                    "nativecode": [],
                },
            ]
        }
    }
    update.args = argparse.Namespace(
        rehash=False,
        systems=["x86_64-linux=universal"],
        dry_run=False,
        check=False,
        skip_verify=True,
    )

    line = asyncio.run(update.update_fdroid_package(pkg, {"https://f-droid.org/repo": index}))
    assert "[upd]" in line and "1.1.0" in line
    pin = json.loads((d / "hashes.json").read_text())
    assert pin["version"] == "1.1.0"
    assert pin["apkName"] == "hyle_110.apk"
    assert (
        pin["architectures"]["x86_64-linux"]["hash"]
        == "sha256-" + base64.b64encode(bytes.fromhex("bb" * 32)).decode()
    )


def test_update_fdroid_package_skips_when_unchanged(monkeypatch, tmp_path):
    d = _write_package(tmp_path, "a.b", "f-droid")
    sri = "sha256-" + base64.b64encode(bytes(range(32))).decode()
    (d / "hashes.json").write_text(
        json.dumps(
            {
                "version": "1.1.0",
                "apkName": "a_110.apk",
                "architectures": {"x86_64-linux": {"archStr": "universal", "hash": sri}},
            }
        )
    )
    pkg = update.Package(d)
    index = {
        "packages": {
            "a.b": [
                {
                    "versionName": "1.1.0",
                    "versionCode": 110,
                    "apkName": "a_110.apk",
                    "hash": "aa" * 32,
                }
            ]
        }
    }
    update.args = argparse.Namespace(
        rehash=False,
        systems=["x86_64-linux=universal"],
        dry_run=False,
        check=False,
        skip_verify=True,
    )
    line = asyncio.run(update.update_fdroid_package(pkg, {"https://f-droid.org/repo": index}))
    assert "[skip]" in line
    # pin untouched
    assert json.loads((d / "hashes.json").read_text())["version"] == "1.1.0"


def test_update_fdroid_package_respects_its_own_repo(monkeypatch, tmp_path):
    # The same app id exists on f-droid.org and IzzyOnDroid with DIFFERENT
    # hashes. A package pinned to Izzy must update against Izzy's index only.
    d = _write_package(
        tmp_path, "com.example.app", "f-droid", "https://apt.izzysoft.de/fdroid/repo"
    )
    (d / "hashes.json").write_text(json.dumps({"version": "", "architectures": {}}))
    pkg = update.Package(d)

    fdroid_index = {
        "packages": {
            "com.example.app": [
                {"versionName": "9.9.9", "versionCode": 999, "apkName": "x.apk", "hash": "11" * 32}
            ]
        }
    }
    izzy_index = {
        "packages": {
            "com.example.app": [
                {"versionName": "1.2.3", "versionCode": 123, "apkName": "y.apk", "hash": "22" * 32}
            ]
        }
    }
    indexes: dict[str, update.Json | None] = {
        "https://f-droid.org/repo": fdroid_index,
        "https://apt.izzysoft.de/fdroid/repo": izzy_index,
    }
    update.args = argparse.Namespace(
        rehash=False,
        systems=["x86_64-linux=universal"],
        dry_run=False,
        check=False,
        skip_verify=True,
    )
    line = asyncio.run(update.update_fdroid_package(pkg, indexes))
    pin = json.loads((d / "hashes.json").read_text())
    assert pin["version"] == "1.2.3"  # from Izzy, not 9.9.9 from f-droid.org
    assert pin["apkName"] == "y.apk"
    assert (
        pin["architectures"]["x86_64-linux"]["hash"]
        == "sha256-" + base64.b64encode(bytes.fromhex("22" * 32)).decode()
    )
    assert "[upd]" in line


def test_update_fdroid_package_not_in_index(tmp_path):
    d = _write_package(tmp_path, "a.b", "f-droid")
    (d / "hashes.json").write_text(json.dumps({"version": "", "architectures": {}}))
    pkg = update.Package(d)
    update.args = argparse.Namespace(
        rehash=False, systems=["x86_64-linux"], dry_run=False, check=False, skip_verify=True
    )
    line = asyncio.run(
        update.update_fdroid_package(pkg, {"https://f-droid.org/repo": {"packages": {}}})
    )
    assert "[warn]" in line


def test_update_fdroid_package_stamps_new_hash_on_all_systems(monkeypatch, tmp_path):
    # A version bump changes the flat hash for EVERY system (the same APK file
    # serves all Nix systems) - stale preserved hashes would break builds.
    d = _write_package(tmp_path, "a.b", "f-droid")
    (d / "hashes.json").write_text(
        json.dumps(
            {
                "version": "1.0.0",
                "apkName": "a_100.apk",
                "architectures": {
                    "x86_64-linux": {"archStr": "universal", "hash": "sha256-old"},
                    "aarch64-linux": {"archStr": "universal", "hash": "sha256-old"},
                },
            }
        )
    )
    pkg = update.Package(d)
    index = {
        "packages": {
            "a.b": [
                {
                    "versionName": "2.0.0",
                    "versionCode": 200,
                    "apkName": "a_200.apk",
                    "hash": "cc" * 32,
                }
            ]
        }
    }
    update.args = argparse.Namespace(
        rehash=False,
        systems=["x86_64-linux=universal"],
        dry_run=False,
        check=False,
        skip_verify=True,
    )
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
    update.args = argparse.Namespace(
        rehash=False,
        systems=["x86_64-linux=universal"],
        dry_run=False,
        check=False,
        skip_verify=True,
    )

    async def fake_latest(app_id, source):
        return "1.0.0"

    def fake_compute(*a, **k):
        raise subprocess.TimeoutExpired(cmd=["apkeep"], timeout=120)

    monkeypatch.setattr(update, "get_latest_version", fake_latest)
    monkeypatch.setattr(update, "compute_sri", fake_compute)
    line = asyncio.run(update.update_package(pkg, asyncio.Semaphore(1)))
    assert line.startswith("[fail]")
    assert "timed out" in line


# ------------------------------------------------------ github-releases path


def test_pick_github_asset_prefers_universal():
    release = {
        "assets": [
            {"name": "app-arm64-v8a-release.apk", "size": 10},
            {"name": "app-universal-release.apk", "size": 20},
            {"name": "app-x86_64-release.apk", "size": 15},
        ]
    }
    asset = update.pick_github_asset(release)
    assert asset is not None
    assert asset["name"] == "app-universal-release.apk"


def test_pick_github_asset_falls_back_to_any_apk():
    fallback = update.pick_github_asset({"assets": [{"name": "foo.apk"}]})
    assert fallback is not None
    assert fallback["name"] == "foo.apk"
    assert update.pick_github_asset({"assets": [{"name": "foo.zip"}]}) is None
    assert update.pick_github_asset({}) is None


def test_human_size():
    assert update.human_size(500) == "500 B"
    assert update.human_size(1024) == "1 KB"
    assert update.human_size(73_500_000) == "70.1 MB"
    assert update.human_size(2_500_000_000) == "2.3 GB"


def test_github_release_history_builds_entries(monkeypatch):
    async def fake_get(url, *a, **k):
        return [
            {
                "tag_name": "v1.1.0",
                "published_at": "2026-05-01T10:00:00Z",
                "assets": [{"name": "app-universal-release.apk", "size": 1234567}],
            },
            {"tag_name": "v1.0.0", "published_at": "2026-01-01T00:00:00Z", "assets": []},
        ]

    monkeypatch.setattr(httpx, "AsyncClient", fake_client(fake_get))
    history = asyncio.run(update.github_release_history("o/r"))
    assert history == [
        {"version": "v1.1.0", "date": "2026-05-01", "size": "1.2 MB"},
        {"version": "v1.0.0", "date": "2026-01-01"},
    ]


def test_update_github_package_pins_latest(monkeypatch, tmp_path):
    d = _write_package(tmp_path, "org.example.app", "github-releases", gh_repo="org/repo")
    (d / "hashes.json").write_text(json.dumps({"version": "", "architectures": {}}))
    pkg = update.Package(d)
    update.args = argparse.Namespace(
        rehash=False,
        systems=["x86_64-linux=universal"],
        dry_run=False,
        check=False,
        skip_verify=True,
    )
    release = {
        "tag_name": "v2.0.0",
        "assets": [{"name": "app-universal-release.apk", "size": 100}],
    }

    async def fake_latest(gh_repo):
        return release

    async def fake_sri(release, asset):
        return "sha256-AbCdEf=="

    monkeypatch.setattr(update, "github_latest_release", fake_latest)
    monkeypatch.setattr(update, "compute_github_sri", fake_sri)
    line = asyncio.run(update.update_github_package(pkg))
    assert "[upd]" in line and "v2.0.0" in line
    pin = json.loads((d / "hashes.json").read_text())
    assert pin["version"] == "v2.0.0"
    assert pin["apkName"] == "app-universal-release.apk"
    assert pin["architectures"]["x86_64-linux"]["hash"] == "sha256-AbCdEf=="


def test_update_github_package_skips_when_unchanged(monkeypatch, tmp_path):
    d = _write_package(tmp_path, "org.example.app", "github-releases", gh_repo="org/repo")
    (d / "hashes.json").write_text(
        json.dumps(
            {"version": "v2.0.0", "apkName": "app-universal-release.apk", "architectures": {}}
        )
    )
    pkg = update.Package(d)
    update.args = argparse.Namespace(
        rehash=False,
        systems=["x86_64-linux=universal"],
        dry_run=False,
        check=False,
        skip_verify=True,
    )

    async def fake_latest(gh_repo):
        return {"tag_name": "v2.0.0", "assets": [{"name": "app-universal-release.apk"}]}

    monkeypatch.setattr(update, "github_latest_release", fake_latest)
    line = asyncio.run(update.update_github_package(pkg))
    assert line.startswith("[skip]")


def test_update_github_package_missing_gh_repo(tmp_path):
    d = _write_package(tmp_path, "org.example.app", "github-releases")
    pkg = update.Package(d)
    line = asyncio.run(update.update_github_package(pkg))
    assert line.startswith("[fail]") and "ghRepo" in line


def fake_client(fake_get: Callable[..., Any]) -> type:
    """Build a fake httpx.AsyncClient class for monkeypatching update.httpx."""

    class _Resp:
        def __init__(self, payload: Any) -> None:
            self._payload = payload

        def raise_for_status(self) -> None:
            pass

        def json(self) -> Any:
            return self._payload

    class _Client:
        def __init__(self, *a: Any, **k: Any) -> None:
            pass

        async def __aenter__(self) -> "_Client":
            return self

        async def __aexit__(self, *a: Any) -> None:
            return None

        async def get(self, url: str, *a: Any, **k: Any) -> _Resp:
            payload = fake_get(url, *a, **k)
            if inspect.isawaitable(payload):
                payload = await payload
            return _Resp(payload)

    return _Client


def test_update_history_github_from_api(monkeypatch, tmp_path):
    d = _write_package(tmp_path, "org.example.app", "github-releases", gh_repo="org/repo")
    pkg = update.Package(d)

    async def fake_history(gh_repo):
        return [{"version": "v1.0.0", "date": "2026-01-01"}]

    monkeypatch.setattr(update, "github_release_history", fake_history)
    update.args = argparse.Namespace(dry_run=False, check=False)
    line = asyncio.run(update.update_history(pkg, asyncio.Semaphore(1)))
    assert line.startswith("[hist]") and "v1.0.0" in line
    assert json.loads((d / "history.json").read_text()) == {
        "versions": [{"version": "v1.0.0", "date": "2026-01-01"}]
    }


def test_update_history_github_no_releases(monkeypatch, tmp_path):
    d = _write_package(tmp_path, "org.example.app", "github-releases", gh_repo="org/repo")
    pkg = update.Package(d)

    async def fake_none(gh_repo):
        return None

    monkeypatch.setattr(update, "github_release_history", fake_none)
    update.args = argparse.Namespace(dry_run=False, check=False)
    line = asyncio.run(update.update_history(pkg, asyncio.Semaphore(1)))
    assert line.startswith("[warn]") and "no releases" in line


# ------------------------------------------------------------- latest version


def test_get_latest_version_falls_back_to_apkpure_page(monkeypatch):
    async def fake_detail(base, app_id):
        return '<html><div data-dt-version="3.2.1"></div></html>'

    monkeypatch.setattr(update, "_apkpure_detail", fake_detail)
    assert asyncio.run(update.get_latest_version("com.app", "apk-pure")) == "3.2.1"


# ------------------------------------------------------------ version history


def test_parse_version_history_includes_hidden_rows():
    html = """
    <ul class="version-list">
      <li class="version dt-version-item" data-dt-version="26.08.20.0" data-dt-version-code="90016056">
        <div class="version-info"><p class="version-date">Updated on Aug 14, 2026</p></div>
        <div class="additional-info">XAPK Aug 14, 2026 120.1 MB</div>
      </li>
      <li class="version dt-version-item hidden" data-dt-version="26.07.10.0" data-dt-version-code="90015905">
        <div class="version-info"><p class="version-date">Updated on Jul 10, 2026</p></div>
        <div class="additional-info">XAPK Jul 10, 2026 131.3 MB</div>
      </li>
      <li class="version dt-version-item" data-dt-version="26.06.20.0" data-dt-version-code="90015833">
        <div class="version-info"><p class="version-date">Updated on Jun 20, 2026</p></div>
        <div class="additional-info">APK Jun 20, 2026 88.4 MB</div>
      </li>
    </ul>
    """
    history = update.parse_version_history(html)
    assert len(history) == 3
    assert history[0] == {
        "version": "26.08.20.0",
        "versionCode": 90016056,
        "date": "Aug 14, 2026",
        "size": "120.1 MB",
    }
    assert history[1]["version"] == "26.07.10.0"  # hidden row is included
    assert history[2]["size"] == "88.4 MB"


def test_parse_version_history_skips_rows_without_version():
    html = '<li class="version" data-dt-version-code="123"></li>'
    assert update.parse_version_history(html) == []


def test_parse_version_history_missing_optional_fields():
    html = '<li class="version" data-dt-version="1.0"></li>'
    assert update.parse_version_history(html) == [{"version": "1.0"}]


def test_history_for_fdroid_sorts_newest_first(tmp_path):
    index = {
        "packages": {
            "a.b": [
                {"versionName": "1.0", "versionCode": 10, "added": "2024-01-01 00:00:00"},
                {"versionName": "3.0", "versionCode": 30, "added": "2026-01-01 00:00:00"},
                {"versionName": "2.0", "versionCode": 20, "added": "2025-01-01 00:00:00"},
            ]
        }
    }
    pkg = update.Package(_write_package(tmp_path, "a.b", "f-droid"))
    versions = asyncio.run(update.history_for_fdroid(pkg, index))
    assert versions is not None
    assert [v["version"] for v in versions] == ["3.0", "2.0", "1.0"]
    assert versions[0]["date"] == "2026-01-01"


def test_history_for_fdroid_none_when_absent(tmp_path):
    pkg = update.Package(_write_package(tmp_path, "a.b", "f-droid"))
    assert asyncio.run(update.history_for_fdroid(pkg, {"packages": {}})) is None


def test_update_history_writes_apkpure_history(monkeypatch, tmp_path):
    d = _write_package(tmp_path, "com.app", "apk-pure")
    pkg = update.Package(d)

    async def fake_fetch(app_id):
        return [{"version": "2.0", "versionCode": 200}, {"version": "1.0", "versionCode": 100}]

    monkeypatch.setattr(update, "fetch_apkpure_history", fake_fetch)
    update.args = argparse.Namespace(dry_run=False, check=False)

    line = asyncio.run(update.update_history(pkg, asyncio.Semaphore(1)))
    assert "[hist]" in line and "2 versions" in line
    assert json.loads((d / "history.json").read_text())["versions"][0]["version"] == "2.0"


def test_update_history_skips_when_unchanged(monkeypatch, tmp_path):
    d = _write_package(tmp_path, "com.app", "apk-pure")
    (d / "history.json").write_text(json.dumps({"versions": [{"version": "2.0"}]}))
    pkg = update.Package(d)

    async def fake_fetch(app_id):
        return [{"version": "2.0"}]

    monkeypatch.setattr(update, "fetch_apkpure_history", fake_fetch)
    update.args = argparse.Namespace(dry_run=False, check=False)
    assert "[skip]" in asyncio.run(update.update_history(pkg, asyncio.Semaphore(1)))


def test_update_history_check_does_not_write(monkeypatch, tmp_path):
    d = _write_package(tmp_path, "com.app", "apk-pure")
    pkg = update.Package(d)

    async def fake_fetch(app_id):
        return [{"version": "2.0"}]

    monkeypatch.setattr(update, "fetch_apkpure_history", fake_fetch)
    update.args = argparse.Namespace(dry_run=False, check=True)
    line = asyncio.run(update.update_history(pkg, asyncio.Semaphore(1)))
    assert line.startswith("[dry]")
    assert not (d / "history.json").exists()


def test_update_history_fdroid_from_index(monkeypatch, tmp_path):
    d = _write_package(tmp_path, "a.b", "f-droid")
    pkg = update.Package(d)
    index = {"packages": {"a.b": [{"versionName": "2.0", "versionCode": 20}]}}
    update.args = argparse.Namespace(dry_run=False, check=False)
    line = asyncio.run(
        update.update_history(pkg, asyncio.Semaphore(1), {"https://f-droid.org/repo": index})
    )
    assert "[hist]" in line
    assert json.loads((d / "history.json").read_text())["versions"][0]["version"] == "2.0"


def test_update_history_warns_when_apkpure_missing(monkeypatch, tmp_path):
    d = _write_package(tmp_path, "com.app", "apk-pure")
    pkg = update.Package(d)

    async def fake_fetch(app_id):
        raise LookupError("no APKPure page found")

    monkeypatch.setattr(update, "fetch_apkpure_history", fake_fetch)
    update.args = argparse.Namespace(dry_run=False, check=False)
    line = asyncio.run(update.update_history(pkg, asyncio.Semaphore(1)))
    assert line.startswith("[warn]") and "no APKPure page" in line


# ------------------------------------------------------- signer fingerprint recording


def test_record_fingerprints_adds_to_verified_json(tmp_path):
    d = _write_package(tmp_path, "com.app", "apk-pure")
    (d / "verified.json").write_text(
        json.dumps({"package": "com.app", "signerFingerprints": [], "source": "APKPure"})
    )
    pkg = update.Package(d)
    assert pkg.record_fingerprints(["aa:bb:cc", "aa:bb:cc"]) is True
    data = json.loads((d / "verified.json").read_text())
    assert data["signerFingerprints"] == ["AABBCC"]
    # idempotent
    assert pkg.record_fingerprints(["AA:BB:CC"]) is False


def test_record_fingerprints_noop_without_verified_json(tmp_path):
    d = _write_package(tmp_path, "com.app", "apk-pure")
    pkg = update.Package(d)
    assert pkg.record_fingerprints(["AA:BB:CC"]) is False
