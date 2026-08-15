"""Unit tests for scripts/recategorize.py (offline)."""

import json

import pytest

import recategorize


def _index(packages):
    return {"packages": {pkg: {"metadata": meta} for pkg, meta in packages.items()}}


def test_metadata_map_flattens_localized_text():
    data = _index({
        "com.foo": {"categories": ["Internet"],
                     "summary": {"en-US": "a web browser", "de": "ein Browser"},
                     "name": {"en-US": "Foo Browser", "de": "Foo"}},
    })
    info = recategorize.metadata_map(data)["com.foo"]
    assert info["summary"] == "a web browser"
    assert info["name"] == "Foo Browser"


def _make_pkgs(tmp_path):
    pkgs = tmp_path / "pkgs"
    for cat, apps in [("misc", ["com.foo.app", "com.bar.browser", "com.unknown.zzz"]),
                      ("tools", ["com.stays.tools"])]:
        for app in apps:
            d = pkgs / cat / app
            d.mkdir(parents=True)
            (d / "package.nix").write_text("{ fetchApk }:\n{}\n")
            (d / "hashes.json").write_text("{}")
    return pkgs


def _cli(pkgs_dir, file, **kw):
    defaults = dict(repo="fdroid", file=file, dry_run=True, all=False, pkgs_dir=pkgs_dir)
    defaults.update(kw)
    return type("Args", (), defaults)()


def test_plan_moves_curated_and_keyword_fallback(tmp_path):
    pkgs = _make_pkgs(tmp_path)
    index = _index({
        "com.foo.app": {"categories": ["Money"]},                 # curated -> finance
        "com.bar.browser": {"categories": ["Internet"], "summary": "a web browser", "name": "Bar"},
        "com.unknown.zzz": {"categories": ["Internet"], "summary": "widgets and doodads", "name": "Zzz"},
    })
    moves = recategorize.plan_moves(pkgs, recategorize.metadata_map(index), all_categories=False)
    by_app = {app: target for _, app, target in moves}
    assert by_app["com.foo.app"] == "finance"       # curated category wins
    assert by_app["com.bar.browser"] == "browser"   # broad bucket + summary keywords
    assert "com.unknown.zzz" not in by_app   # stays in misc -> not in moves
    # tools/ app is untouched when not --all
    assert "com.stays.tools" not in by_app


def test_main_moves_files(monkeypatch, tmp_path, capsys):
    pkgs = _make_pkgs(tmp_path)
    index = _index({
        "com.foo.app": {"categories": ["Money"]},
        "com.bar.browser": {"categories": ["Internet"], "summary": "a web browser", "name": "Bar"},
    })
    index_path = tmp_path / "index-v2.json"
    index_path.write_text(json.dumps(index))

    cli = _cli(pkgs, index_path, dry_run=False)
    recategorize.main(cli)

    assert (pkgs / "finance" / "com.foo.app" / "package.nix").exists()
    assert (pkgs / "browser" / "com.bar.browser" / "package.nix").exists()
    assert not (pkgs / "misc" / "com.foo.app").exists()
    out = capsys.readouterr().out
    assert "moved 2 apps" in out
    # files moved intact
    assert (pkgs / "finance" / "com.foo.app" / "hashes.json").read_text() == "{}"


def test_main_dry_run_writes_nothing(tmp_path, capsys):
    pkgs = _make_pkgs(tmp_path)
    index = _index({"com.foo.app": {"categories": ["Money"]}})
    index_path = tmp_path / "index-v2.json"
    index_path.write_text(json.dumps(index))

    with pytest.raises(SystemExit):
        recategorize.main(_cli(pkgs, index_path, dry_run=True))
    assert (pkgs / "misc" / "com.foo.app").exists()
    out = capsys.readouterr().out
    assert "finance" in out and "com.foo.app" in out


def test_all_considers_non_misc_dirs(tmp_path):
    pkgs = _make_pkgs(tmp_path)
    index = _index({"com.stays.tools": {"categories": ["Money"]}})
    moves = recategorize.plan_moves(pkgs, recategorize.metadata_map(index), all_categories=True)
    assert ("tools", "com.stays.tools", "finance") in moves
    moves_default = recategorize.plan_moves(pkgs, recategorize.metadata_map(index), all_categories=False)
    assert ("tools", "com.stays.tools", "finance") not in moves_default
