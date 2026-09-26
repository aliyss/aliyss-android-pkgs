# AGENTS.md

Conventions for this repository. Read this before changing anything under
`pkgs/` or `scripts/` — the tree is large and machine-verified, so a rule broken
in one place is usually caught by a test rather than by a reviewer.

## The layout rule

Apps live in `pkgs/by-name/<shard>/<app-id>/`. **Nothing lists the apps**: the
shard is derived from the app id, `pkgs/default.nix` finds packages by walking
the tree, and `update.py` finds work the same way. Adding an app is one
directory.

The rule is written down exactly twice, and they must stay in step:

- `scripts/layout.py` — `shard_for`, `app_dir`, `iter_app_dirs`. Every Python
  path goes through it; **never** build an app path by hand.
- `pkgs/default.nix` — `shardOf`, the Nix twin used by the package walker.
  `lib/recommended.nix` walks the same tree.

`tests/test_layout.py` pins the rule on hand-written expectations and
`tests/test_repo_structure.py::test_app_dirs_live_in_their_shard` asserts that
every directory on disk sits in the shard its own name implies. If you change
the shard key you must move the tree, update both implementations and both
tests in one change.

The shard is two characters: the first two of the app's publisher label (the
label after the TLD), or of the app id when that label is shorter than two
characters. Do not "optimise" it to the first two characters of the app id —
that puts a third of the repository in `co/`.

## App directories

| file | who writes it |
|---|---|
| `package.nix` | a seeder; static, calls `fetchApk` and reads `./hashes.json` |
| `hashes.json` | `scripts/update.py` — **generated, never hand-edited** |
| `history.json` | `scripts/update.py --history` — generated |
| `verified.json` | a seeder (signer fingerprints + attribution) |
| `recommended.json` | a human, optionally: the curated `recommended` block |

- Hashes are SRI (`sha256-...`). `f-droid` and `github-releases` pins are flat
  file hashes (`outputHashMode = "flat"`); everything else is a recursive hash
  of apkeep's download layout.
- A seeded app with an empty `version` is **not** in the package set
  (`pkgs/default.nix` filters it) until `update.py` pins it. That is deliberate:
  `nix flake check` stays green on a fresh seed. An unpinned directory must have
  a `verified.json`.
- To add an app, use a seeder rather than writing files by hand:
  `seed_fdroid.py` (zero downloads, signed index), `seed_verified_apps.py`
  (fingerprints only), `seed_apkpure.py` (empty pin, needs a later update run).

## Changing state, not just versions

`android-enforce` owns the runtime layer. The declared shape is one block per
app id and the config is **overrides** by default; `managed` is opt-in per app
or globally and only ever removes grants. `recommended.json` is a curated
baseline that ships next to the app. `tests/test_repo_structure.py` validates the
sidecar schema — every key and value, because a typo in config data is silently
a no-op on a phone.

The walk reads the device once and writes once, each as a single root script,
and the config is loaded into arrays once (`tests/enforce_walk_test.sh` guards
this off the device). Keep it that way: a root spawn per setting or a `jq` per
field is the difference between a switch taking seconds and minutes. The
snapshot the reads fill is addressed by key, so a marker and its lookup must
agree — an off-by-one in the key reads as "empty", which silently turns a
comparison into a no-op.

## Gates

Run these before committing. CI runs the same things:

```console
nix develop                      # shellcheck, ruff, mypy, pytest, python
ruff check scripts/ tests/
ruff format --check scripts/ tests/
mypy scripts/ tests/             # strict
pytest -q tests/
shellcheck --severity=warning -s bash scripts/*.sh tests/*.sh tests/fake/*
bash tests/enforce_config_test.sh   # config folding (--print-effective)
bash tests/enforce_walk_test.sh     # the enforce walk, off the device
nix flake check                  # the above, plus the Nix-side checks
```

- Python is **strictly typed** (`mypy --strict`): annotate everything, and cast
  at JSON/HTML boundaries instead of widening types.
- Prefer extending `tests/test_repo_structure.py` when you add an invariant that
  must hold for all 4000+ apps; unit tests under `tests/` should stay offline and
  network-free.
- Shell scripts are bash and linted with `shellcheck --severity=warning`.

## Pins are updated by automation

`.github/workflows/update.yml` runs nightly and opens a PR with the pin bumps.
Review it like any other change; do not push pin updates straight to `master`.
No credentials are needed: every source used here publishes its metadata (the
F-Droid index, the GitHub API).

## Do not

- Hand-edit `hashes.json` or `history.json`, or copy an app directory to a new
  path without going through the shard rule.
- Add an index/list file of app names — discovery is by walking the tree.
- Commit a downloaded APK, or anything from a device.
