"""Unit tests for scripts/seed_verified_apps.py (offline)."""

import json

import pytest

import seed_verified_apps as sva


# ------------------------------------------------------------------ pnames


def test_derive_pname_overrides():
    assert sva.derive_pname("org.thoughtcrime.securesms") == "signal"
    assert sva.derive_pname("org.telegram.messenger") == "telegram"
    assert sva.derive_pname("com.spotify.music") == "spotify"


def test_derive_pname_generic_suffix_and_domains():
    assert sva.derive_pname("de.jepfa.hyle_x") == "hyle_x"
    assert sva.derive_pname("com.android.chrome") == "chrome"  # drop com + generic android
    assert sva.derive_pname("org.mozilla.fenix") == "fenix"
    assert sva.derive_pname("app.simple.notes") == "notes"
    assert sva.derive_pname("io.github.muntashirakon.AppManager") == "AppManager"


# ----------------------------------------------------------------- rendering


def test_render_package_template():
    text = sva.render_package("com.spotify.music", "spotify")
    assert 'pname = "spotify"' in text
    assert 'appId = "com.spotify.music"' in text
    assert "pin.version" in text and "pin.architectures" in text
    assert "hashes.json" in text


def test_render_pin_is_empty_lockfile():
    pin = json.loads(sva.render_pin())
    assert pin == {"version": "", "architectures": {}}


def test_render_verified_attribution():
    data = json.loads(sva.render_verified("org.app", ["AA:BB"]))
    assert data["package"] == "org.app"
    assert data["signerFingerprints"] == ["AA:BB"]
    assert data["source"] == "privacyguides/verified-apps"
    assert "source-license" in data and "source-license-url" in data


# ------------------------------------------------------------------- main()


def _yaml(packages: list[dict[str, object]]) -> dict[str, object]:
    return {"schema": 1, "packages": packages}


def test_main_dry_run_lists_plan(monkeypatch, tmp_path, capsys):
    monkeypatch.setattr(sva, "PKGS_DIR", tmp_path / "pkgs")
    monkeypatch.setattr(
        sva,
        "load_data",
        lambda src: _yaml(
            [
                {
                    "package": "org.thoughtcrime.securesms",
                    "signature": [{"fingerprint": "aa bb cc"}],
                },
                {"package": "com.spotify.music", "signature": [{"fingerprint": "11 22 33"}]},
            ]
        ),
    )
    cli = type("Args", (), {"file": None, "only": None, "limit": None, "dry_run": True})()
    with pytest.raises(SystemExit):
        sva.main(cli)
    out = capsys.readouterr().out
    assert "th/org.thoughtcrime.securesms" in out
    assert "sp/com.spotify.music" in out


def test_main_seeds_files_into_pkgs(monkeypatch, tmp_path):
    monkeypatch.setattr(sva, "PKGS_DIR", tmp_path / "pkgs")
    monkeypatch.setattr(
        sva,
        "load_data",
        lambda src: _yaml(
            [
                {
                    "package": "org.thoughtcrime.securesms",
                    "signature": [{"fingerprint": "aa bb cc"}],
                },
            ]
        ),
    )
    cli = type("Args", (), {"file": None, "only": None, "limit": None, "dry_run": False})()
    sva.main(cli)

    app_dir = tmp_path / "pkgs" / "by-name" / "th" / "org.thoughtcrime.securesms"
    assert (app_dir / "package.nix").exists()
    assert (app_dir / "hashes.json").exists()
    verified = json.loads((app_dir / "verified.json").read_text())
    assert verified["signerFingerprints"] == ["aa bb cc"]
    assert json.loads((app_dir / "hashes.json").read_text()) == {"version": "", "architectures": {}}


def test_main_skips_existing_apps(monkeypatch, tmp_path, capsys):
    existing = tmp_path / "pkgs" / "by-name" / "ex" / "com.existing.app"
    existing.mkdir(parents=True)
    (existing / "package.nix").write_text("{ fetchApk }:\n{}\n")
    monkeypatch.setattr(sva, "PKGS_DIR", tmp_path / "pkgs")
    monkeypatch.setattr(
        sva,
        "load_data",
        lambda src: _yaml(
            [
                {"package": "com.existing.app", "signature": [{"fingerprint": "aa"}]},
                {"package": "org.other.app", "signature": [{"fingerprint": "bb"}]},
            ]
        ),
    )
    cli = type("Args", (), {"file": None, "only": None, "limit": None, "dry_run": False})()
    sva.main(cli)
    assert not (tmp_path / "pkgs" / "by-name" / "ex" / "com.existing.app" / "hashes.json").exists()
    assert (tmp_path / "pkgs" / "by-name" / "ot" / "org.other.app" / "hashes.json").exists()


def test_main_respects_only_and_limit(monkeypatch, tmp_path, capsys):
    monkeypatch.setattr(sva, "PKGS_DIR", tmp_path / "pkgs")
    monkeypatch.setattr(
        sva,
        "load_data",
        lambda src: _yaml(
            [
                {"package": "a.b", "signature": [{"fingerprint": "aa"}]},
                {"package": "c.d", "signature": [{"fingerprint": "bb"}]},
                {"package": "e.f", "signature": [{"fingerprint": "cc"}]},
            ]
        ),
    )
    cli = type("Args", (), {"file": None, "only": None, "limit": 2, "dry_run": False})()
    sva.main(cli)
    created = sorted(p.parent.name for p in (tmp_path / "pkgs").rglob("hashes.json"))
    assert created == ["a.b", "c.d"]
