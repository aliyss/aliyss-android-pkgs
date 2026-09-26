#!/usr/bin/env python3
"""Where an app's directory lives: ``pkgs/by-name/<shard>/<app-id>/``.

The tree is laid out by *name*, like nixpkgs' ``pkgs/by-name``: the app id is
the directory name and the shard is computed from that name alone. Nothing
lists the apps, so adding one is a single ``mkdir`` (which is exactly what the
seeders do) and ``pkgs/default.nix`` discovers it by walking the tree.

The shard is the first two characters of the app's **publisher label** — the
label after the TLD::

    com.spotify.music                    -> sp   (publisher "spotify")
    org.thoughtcrime.securesms           -> th
    io.github.muntashirakon.AppManager   -> gi   ("github" is the second-level
                                                  domain of github.io)
    a2dp.Vol                             -> a2   (two labels: use the first)
    S.N.A.K.E                            -> sn   ("n" is too short: use the id)

Android ids are reverse-DNS, so sharding on the *whole* id — nixpkgs' rule,
the first two characters of the name — would bury every ``com.*`` id in one
directory: 1881 of the repository's 4199 apps under ``co/``. The publisher
label instead spreads those apps over 471 shards, the largest of which holds
285. A two-label id uses its first label, and a label shorter than two
characters falls back to the app id, so a shard is always exactly two
characters.

``app_dir()`` is the only place the layout is written down: the seeders, the
updater and the structural tests all go through it, so the tree cannot drift
out of shape in one place without the others noticing.
"""

from __future__ import annotations

import re
from collections.abc import Iterator
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
PKGS_DIR = REPO_ROOT / "pkgs"
# The shard directory name, spelled once: pkgs/default.nix and
# lib/recommended.nix walk the same layout on the Nix side.
BY_NAME = "by-name"

_ALNUM = re.compile(r"[^A-Za-z0-9]")

# Labels that name the packaging rather than the app; derive_pname skips them.
_GENERIC_SUFFIX = {
    "app",
    "apps",
    "android",
    "mobile",
    "player",
    "client",
    "web",
    "gms",
    "play",
    "fdroid",
    "accrescent",
    "oss",
    "release",
    "repo",
    "core",
    "lite",
    "pro",
    "prod",
    "debug",
    "nightly",
    "beta",
    "test",
}

# pname override map for well-known apps (empty -> derive from app id).
PNAME_OVERRIDES = {
    "org.thoughtcrime.securesms": "signal",
    "org.telegram.messenger": "telegram",
    "org.mozilla.firefox": "firefox",
    "com.spotify.music": "spotify",
}


def publisher_label(app_id: str) -> str:
    """The label that names the app's publisher (``com.spotify.music`` -> ``spotify``).

    Reverse-DNS ids are ``<tld>.<publisher>[.<app>...]``, so the publisher is the
    second label. Ids with only two labels have no app path and use the first.
    """
    parts = app_id.split(".")
    return parts[1] if len(parts) > 2 else parts[0]


def shard_for(app_id: str) -> str:
    """The two-character shard directory an app id belongs in."""
    label = _ALNUM.sub("", publisher_label(app_id))
    if len(label) < 2:
        # Single-character publisher labels exist (S.N.A.K.E -> "N"): fall back
        # to the id itself so every shard stays two characters wide.
        label = _ALNUM.sub("", app_id)
    return label[:2].lower()


def app_dir(app_id: str, pkgs_dir: Path = PKGS_DIR) -> Path:
    """The directory an app id belongs in, whether or not it exists yet."""
    return pkgs_dir / BY_NAME / shard_for(app_id) / app_id


def iter_app_dirs(pkgs_dir: Path = PKGS_DIR) -> Iterator[Path]:
    """Every app directory in the tree, sorted by shard then app id.

    Yields the directories themselves rather than a (shard, dir) pair: the app
    id is the directory name, and the shard is derivable from it, so a caller
    that needs the shard has made a mistake.
    """
    by_name = pkgs_dir / BY_NAME
    if not by_name.is_dir():
        return
    for shard in sorted(by_name.iterdir()):
        if not shard.is_dir():
            continue
        for app in sorted(shard.iterdir()):
            if app.is_dir():
                yield app


def existing_app_ids(pkgs_dir: Path = PKGS_DIR) -> set[str]:
    """App ids already seeded (a directory holding a package.nix)."""
    return {app.name for app in iter_app_dirs(pkgs_dir) if (app / "package.nix").is_file()}


def derive_pname(app_id: str) -> str:
    """A short, human name for an app id (used as the package's ``pname``)."""
    if app_id in PNAME_OVERRIDES:
        return PNAME_OVERRIDES[app_id]
    parts = app_id.split(".")
    primary = parts[-2] if parts[-1].lower() in _GENERIC_SUFFIX and len(parts) > 1 else parts[-1]
    # drop leading "com"/"org"/"app"/co.xx country domains as noise
    while (
        primary.lower() in {"com", "org", "app", "net", "io", "co", "cc", "at", "ch", "appinventor"}
        and len(parts) > 1
    ):
        parts = parts[:-1]
        primary = parts[-1]
    return primary
