"""Unit tests for scripts/seed_apkpure.py (offline)."""

import json

import seed_apkpure as sap


def test_render_verified_attribution_only():
    data = json.loads(sap.render_verified("com.spotify.music"))
    assert data["package"] == "com.spotify.music"
    assert data["signerFingerprints"] == []
    assert "APKPure" in data["source"]
    assert data["source-url"] == "https://apkpure.com"


def test_render_history_empty():
    assert json.loads(sap.render_history()) == {"versions": []}


def test_seed_one_writes_all_sidecars(monkeypatch, tmp_path):
    monkeypatch.setattr(sap, "PKGS_DIR", tmp_path / "pkgs")
    rel = sap.seed_one("com.spotify.music", set())
    # by-name: com.spotify.music -> publisher "spotify" -> shard "sp".
    assert rel == "pkgs/by-name/sp/com.spotify.music"
    d = tmp_path / "pkgs" / "by-name" / "sp" / "com.spotify.music"
    assert (d / "package.nix").exists()
    assert json.loads((d / "hashes.json").read_text()) == {"version": "", "architectures": {}}
    assert json.loads((d / "verified.json").read_text())["signerFingerprints"] == []
    assert json.loads((d / "history.json").read_text()) == {"versions": []}


def test_seed_one_skips_existing(monkeypatch, tmp_path):
    monkeypatch.setattr(sap, "PKGS_DIR", tmp_path / "pkgs")
    assert sap.seed_one("com.spotify.music", {"com.spotify.music"}) is None


def test_fill_one_adds_missing_sidecars(monkeypatch, tmp_path):
    d = tmp_path / "pkgs" / "by-name" / "ol" / "com.old.app"
    d.mkdir(parents=True)
    (d / "package.nix").write_text("{ fetchApk }:\n{}\n")
    (d / "hashes.json").write_text("{}")
    written = sap.fill_one(d)
    assert written == ["verified.json", "history.json"]
    assert (d / "verified.json").exists()
    assert (d / "history.json").exists()
    # second run is a no-op
    assert sap.fill_one(d) == []


def test_fill_main_skips_fdroid_apps(monkeypatch, tmp_path, capsys):
    pkgs = tmp_path / "pkgs"
    fd = pkgs / "by-name" / "fd" / "org.fdroid.app"
    fd.mkdir(parents=True)
    (fd / "package.nix").write_text('{ fetchApk }:\n{ source = "f-droid"; }\n')
    ap = pkgs / "by-name" / "ap" / "com.apkpure.app"
    ap.mkdir(parents=True)
    (ap / "package.nix").write_text("{ fetchApk }:\n{}\n")
    monkeypatch.setattr(sap, "PKGS_DIR", pkgs)
    cli = type("Args", (), {"fill": True, "app_ids": [], "file": None, "pkgs_dir": pkgs})()
    sap.main(cli)
    out = capsys.readouterr().out
    assert "filled sidecars on 1 apps" in out
    assert (fd / "verified.json").exists() is False  # f-droid untouched
    assert (ap / "verified.json").exists() is True
