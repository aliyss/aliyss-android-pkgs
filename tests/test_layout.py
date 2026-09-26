"""Unit tests for scripts/layout.py — the by-name shard rule (offline).

The shard decides where an app directory lives, and pkgs/default.nix recomputes
it in Nix so the package set can be found without an index. If the two ever
disagree, apps silently vanish from the flake, so the rule is pinned here on
hand-written expectations rather than being read back from the implementation.
"""

import pytest

import layout


# --------------------------------------------------------------- the shard


@pytest.mark.parametrize(
    "app_id,expected",
    [
        # Three or more labels: the publisher is the label after the TLD.
        ("com.spotify.music", "sp"),
        ("org.thoughtcrime.securesms", "th"),
        ("org.torproject.android", "to"),
        ("de.jepfa.hyle_x", "je"),
        ("io.github.muntashirakon.AppManager", "gi"),  # github.io is the domain
        ("com.darkempire78.opencalculator", "da"),
        # Exactly two labels: there is no app path, so the first label is used
        # (which for a reverse-DNS id means the TLD itself).
        ("a2dp.Vol", "a2"),
        ("com.termux", "co"),
        # Three labels again: the middle one is the publisher.
        ("org.fdroid.fdroid", "fd"),
        # A one-character publisher label cannot fill a shard: fall back to the
        # id itself so every shard stays two characters wide.
        ("S.N.A.K.E", "sn"),
        # Case and separators are dropped, so the shard is always lowercase.
        ("InfinityLoop1309.NewPipeEnhanced", "in"),
        # Defensive: ids that start with a digit still shard.
        ("1.2.3", "12"),
    ],
)
def test_shard_for_uses_the_publisher_label(app_id, expected):
    assert layout.shard_for(app_id) == expected


def test_shards_are_two_lowercase_alphanumerics():
    """Every real app id must produce a usable directory name."""
    for app_id in [
        "com.spotify.music",
        "a2dp.Vol",
        "S.N.A.K.E",
        "org.fdroid.fdroid",
        "io.github.muntashirakon.AppManager",
        "1.2.3",
        "x.y",
        "com.termux",
    ]:
        shard = layout.shard_for(app_id)
        assert len(shard) == 2, f"{app_id}: shard {shard!r} is not two characters"
        # Digits have no case, so `islower` is the wrong test for e.g. "12".
        assert shard.isalnum() and shard == shard.lower(), (
            f"{app_id}: shard {shard!r} is not [a-z0-9]{{2}}"
        )


def test_publisher_label():
    assert layout.publisher_label("com.spotify.music") == "spotify"
    assert layout.publisher_label("a2dp.Vol") == "a2dp"
    assert layout.publisher_label("io.github.muntashirakon.AppManager") == "github"


# ------------------------------------------------------------- the tree


def test_app_dir_is_derived_from_the_app_id():
    expected = layout.PKGS_DIR / "by-name" / "sp" / "com.spotify.music"
    assert layout.app_dir("com.spotify.music") == expected


def test_app_dir_round_trips(tmp_path):
    """The app id names its own directory, and the shard names its parent."""
    for app_id in ["com.spotify.music", "a2dp.Vol", "S.N.A.K.E", "org.fdroid.fdroid"]:
        d = layout.app_dir(app_id, tmp_path)
        assert d.name == app_id
        assert d.parent.name == layout.shard_for(app_id)
        assert d.parent.parent.name == layout.BY_NAME


def test_iter_app_dirs_finds_what_app_dir_writes(tmp_path):
    written = []
    for app_id in ["com.spotify.music", "org.torrent.app", "a2dp.Vol"]:
        d = layout.app_dir(app_id, tmp_path)
        d.mkdir(parents=True)
        (d / "package.nix").write_text("{ fetchApk }:\n{}\n")
        written.append(app_id)

    # A directory outside by-name is not an app: the layout is not "any dir".
    (tmp_path / "misc").mkdir()

    found = [d.name for d in layout.iter_app_dirs(tmp_path)]
    assert found == sorted(written)
    assert layout.existing_app_ids(tmp_path) == set(written)


def test_existing_app_ids_ignores_dirs_without_a_package(tmp_path):
    """Seeding is keyed on package.nix, so a stray empty dir must not count."""
    (layout.app_dir("com.spotify.music", tmp_path)).mkdir(parents=True)
    assert layout.existing_app_ids(tmp_path) == set()

    real = layout.app_dir("org.real.app", tmp_path)
    real.mkdir(parents=True)
    (real / "package.nix").write_text("{ fetchApk }:\n{}\n")
    assert layout.existing_app_ids(tmp_path) == {"org.real.app"}


def test_iter_app_dirs_tolerates_a_missing_tree(tmp_path):
    """Before the first seed there is no pkgs/by-name; that is not an error."""
    assert list(layout.iter_app_dirs(tmp_path)) == []
