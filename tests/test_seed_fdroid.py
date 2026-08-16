"""Unit tests for scripts/seed_fdroid.py (offline)."""

import base64
import json
from typing import Any

import pytest

import seed_fdroid as sfd

Json = dict[str, Any]


def _entry(
    version_name: str = "1.1.0",
    version_code: int = 110,
    apk_name: str = "a_110.apk",
    digest: str | None = None,
    nativecode: list[str] | None = None,
    signer: str | None = None,
) -> Json:
    return {
        "versionName": version_name,
        "versionCode": version_code,
        "apkName": apk_name,
        "hash": digest or "ab" * 32,
        "signer": signer or "ab" * 32,
        "nativecode": nativecode or [],
    }


# ------------------------------------------------------------ selection logic


def test_pick_latest_uses_version_code():
    entries = [_entry(version_code=100), _entry(version_code=300), _entry(version_code=200)]
    latest = sfd.pick_latest(entries)
    assert latest is not None
    assert latest["versionCode"] == 300
    assert sfd.pick_latest([]) is None


def test_is_universal():
    assert sfd.is_universal(_entry())
    assert sfd.is_universal(_entry(nativecode=["arm64-v8a", "armeabi-v7a", "x86", "x86_64"]))
    assert not sfd.is_universal(_entry(nativecode=["arm64-v8a"]))
    assert not sfd.is_universal(_entry(nativecode=["x86_64"]))


def test_hex_to_fingerprint():
    assert sfd.hex_to_fingerprint("aabbcc") == "AA:BB:CC"
    assert sfd.hex_to_fingerprint("AA:BB:CC") == "AA:BB:CC"  # colon-separated input is fine too
    assert len(sfd.hex_to_fingerprint("ab" * 32)) == 95  # 32 bytes -> 32 groups joined by colons


def test_render_pin_flat_hash_for_all_systems():
    digest = bytes(range(32))
    entry = _entry(digest=digest.hex())
    pin = json.loads(sfd.render_pin(entry))
    assert pin["version"] == "1.1.0"
    assert pin["apkName"] == "a_110.apk"
    expected = "sha256-" + base64.b64encode(digest).decode()
    for system in ("x86_64-linux", "aarch64-linux", "aarch64-darwin"):
        assert pin["architectures"][system] == {"archStr": "universal", "hash": expected}


def test_render_package_template():
    text = sfd.render_package("de.jepfa.hyle_x", "hyle", "https://f-droid.org/repo")
    # the header must be the exact valid Nix lambda, e.g. `{ fetchApk }:`
    assert text.splitlines()[0] == "{ fetchApk }:"
    assert 'source = "f-droid"' in text
    assert 'repoUrl = "https://f-droid.org/repo"' in text
    assert "apkName = pin.apkName" in text
    assert 'appId = "de.jepfa.hyle_x"' in text


def test_render_verified_attribution():
    entry = _entry(signer="aabbccdd")
    data = json.loads(
        sfd.render_verified("a.b", entry, "https://f-droid.org/repo/index-v1.json", "f-droid.org")
    )
    assert data["package"] == "a.b"
    assert data["signerFingerprints"] == ["AA:BB:CC:DD"]
    assert "f-droid.org" in data["source"]
    assert data["source-url"] == "https://f-droid.org/repo/index-v1.json"


# --------------------------------------------------------------------- main()


def _index(packages: Json) -> Json:
    return {"schema": 1, "packages": packages}


def test_main_dry_run_skips_per_abi_by_default(monkeypatch, capsys):
    monkeypatch.setattr(
        sfd,
        "load_index",
        lambda src, repo_url=None: _index(
            {
                "org.universal.app": [_entry(version_name="1.0", version_code=10)],
                "org.armonly.app": [
                    _entry(version_name="1.0", version_code=10, nativecode=["arm64-v8a"])
                ],
            }
        ),
    )
    cli = type(
        "Args",
        (),
        {
            "file": None,
            "repo": "https://f-droid.org/repo",
            "dry_run": True,
            "limit": None,
            "only": None,
            "all": False,
            "pkgs_dir": None,
        },
    )()
    with pytest.raises(SystemExit):
        sfd.main(cli)
    out = capsys.readouterr().out
    assert "misc/org.universal.app" in out
    assert "org.armonly.app" not in out


def test_main_all_includes_per_abi(monkeypatch, capsys):
    monkeypatch.setattr(
        sfd,
        "load_index",
        lambda src, repo_url=None: _index(
            {
                "org.armonly.app": [
                    _entry(version_name="1.0", version_code=10, nativecode=["arm64-v8a"])
                ],
            }
        ),
    )
    cli = type(
        "Args",
        (),
        {
            "file": None,
            "repo": "https://f-droid.org/repo",
            "dry_run": True,
            "limit": None,
            "only": None,
            "all": True,
            "pkgs_dir": None,
        },
    )()
    with pytest.raises(SystemExit):
        sfd.main(cli)
    assert "org.armonly.app" in capsys.readouterr().out


def test_main_seeds_fully_pinned_apps(monkeypatch, tmp_path):
    digest = bytes(range(32)).hex()
    monkeypatch.setattr(
        sfd,
        "load_index",
        lambda src, repo_url=None: _index(
            {
                "org.universal.app": [
                    _entry(
                        version_name="2.0",
                        version_code=20,
                        apk_name="org.universal.app_20.apk",
                        digest=digest,
                    )
                ],
            }
        ),
    )
    cli = type(
        "Args",
        (),
        {
            "file": None,
            "repo": "https://f-droid.org/repo",
            "dry_run": False,
            "limit": None,
            "only": None,
            "all": False,
            "pkgs_dir": tmp_path / "pkgs",
        },
    )()
    sfd.main(cli)

    app_dir = tmp_path / "pkgs" / "misc" / "org.universal.app"
    assert (app_dir / "package.nix").exists()
    pin = json.loads((app_dir / "hashes.json").read_text())
    assert pin["version"] == "2.0"
    assert pin["apkName"] == "org.universal.app_20.apk"
    assert (
        pin["architectures"]["x86_64-linux"]["hash"]
        == "sha256-" + base64.b64encode(bytes(range(32))).decode()
    )
    verified = json.loads((app_dir / "verified.json").read_text())
    assert verified["signerFingerprints"] == [":".join(["AB"] * 32)]


def test_main_skips_existing(monkeypatch, tmp_path):
    existing = tmp_path / "pkgs" / "misc" / "org.existing.app"
    existing.mkdir(parents=True)
    (existing / "package.nix").write_text("{ fetchApk }:\n{}\n")
    monkeypatch.setattr(
        sfd,
        "load_index",
        lambda src, repo_url=None: _index(
            {
                "org.existing.app": [_entry()],
                "org.new.app": [_entry(version_name="1.0", version_code=10)],
            }
        ),
    )
    cli = type(
        "Args",
        (),
        {
            "file": None,
            "repo": "https://f-droid.org/repo",
            "dry_run": False,
            "limit": None,
            "only": None,
            "all": False,
            "pkgs_dir": tmp_path / "pkgs",
        },
    )()
    sfd.main(cli)
    assert not (tmp_path / "pkgs" / "misc" / "org.existing.app" / "hashes.json").exists()
    assert (tmp_path / "pkgs" / "misc" / "org.new.app" / "hashes.json").exists()


def test_main_respects_limit(monkeypatch, tmp_path):
    monkeypatch.setattr(
        sfd,
        "load_index",
        lambda src, repo_url=None: _index(
            {f"org.app{i}.example": [_entry(version_name="1.0", version_code=10)] for i in range(5)}
        ),
    )
    cli = type(
        "Args",
        (),
        {
            "file": None,
            "repo": "https://f-droid.org/repo",
            "dry_run": False,
            "limit": 2,
            "only": None,
            "all": False,
            "pkgs_dir": tmp_path / "pkgs",
        },
    )()
    sfd.main(cli)
    created = sorted(p.name for p in (tmp_path / "pkgs").rglob("hashes.json"))
    assert len(created) == 2
