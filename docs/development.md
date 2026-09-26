# Development

How apps get into the tree and how the tooling around it is run: seeding from
the indexes, the lint/type/test gates, and what `nix flake check` covers.

## Seeding

```console
# F-Droid first (canonical), then IzzyOnDroid (adds only apps F-Droid lacks)
python scripts/seed_fdroid.py                      # ~3.4k apps from f-droid.org
python scripts/seed_fdroid.py --repo izzy          # ~700 more from IzzyOnDroid

# APKPure apps (no signed index: scaffolds an empty pin + attribution-only
# verified.json; fingerprints are recorded by update.py after the first
# verified download)
python scripts/seed_apkpure.py com.spotify.music
python scripts/seed_apkpure.py --from-file apps.txt
python scripts/seed_apkpure.py --fill              # add missing sidecars to existing apk-pure apps
```

`seed_fdroid.py` only seeds apps whose latest APK is universal (or covers all
four ABIs in one file); per-ABI-only APKs are skipped unless `--all`. Use
`--dry-run`, `--limit`, `--only <app-id>` to preview, and `--from-file` to
reuse a downloaded `index-v1.json`.

`scripts/seed_verified_apps.py` seeds from the privacyguides/verified-apps
signing-certificate database (fingerprints only; pin with `update.py` after).

## Tooling

Tooling is declared in `pyproject.toml` (the single source of truth for
dependencies, pytest and ruff configuration); `scripts/requirements.txt` is
gone. Either use the Nix devShell (preferred on NixOS) or a plain venv:

```console
# Nix:
nix develop

# or a standard venv:
python3 -m venv .venv
.venv/bin/pip install -e ".[dev]"
```

Run the same gates CI does:

```console
ruff check scripts/ tests/          # lint (E/F/I/UP/B rule set)
ruff format --check scripts/ tests/ # formatting
mypy scripts/ tests/                # strict type checking
pytest tests/                       # unit tests + structural invariants
shellcheck --severity=warning -s bash scripts/*.sh tests/*.sh tests/fake/*   # device-facing scripts + tests
ruff format scripts/ tests/         # auto-format
```

`nix develop` provides all of it (`shellcheck`, `ruff`, `mypy`, `pytest`,
`apkeep`). `nix flake check` runs the same gates as
`checks.{shell,tests,enforce-config,enforce-walk}`, so a green CI never covers
something the flake does not.

The scripts are strictly typed (`mypy --strict`): JSON payloads from external
APIs are explicitly `dict[str, Any]`/`cast` at the boundary, everything else
is fully annotated. Test functions keep pytest's convention of no return
annotations; the rest of the test code is strict too.

`flake.nix`'s `testPython` (used by the offline test check) keeps the exact
same package set as `pyproject.toml`, so the Nix and venv workflows never
diverge.

## Testing

```console
nix flake check        # evaluates all packages + runs the offline test suite
                       # (ruff lint + format + mypy gates, then pytest)
pytest tests/          # unit tests + structural invariants over all of pkgs/
```

The suite covers the scripts' logic and the whole `pkgs/` tree: every app
must have `package.nix` + `hashes.json`, pins must follow the schema, pinned
apps must have hashes, unpinned seeds must be empty, f-droid apps must carry
`apkName` + a flat hash, and each f-droid app's `repoUrl` must identify its
own provider. New invariants belong there when they must hold for every app.

`android-enforce` has two device-free shell tests, both run by `nix flake check`
(`checks.enforce-config`, `checks.enforce-walk`):

- `tests/enforce_config_test.sh` covers how a config is folded — the canonical
  per-app layout, the older flat one, the curated baseline and its precedence.
  It only needs `--print-effective`.
- `tests/enforce_walk_test.sh` covers what the walk then *decides*. A fake `su`
  runs the root scripts the enforcer generates, and fake `dumpsys`/`appops`/
  `pm`/`settings` on `$AS_SYSTEM_PATH` answer from fixtures, so the managed
  posture, the drift report and the listener state are exercised with no device
  and no root. It is the regression guard for the mode-loading and
  listener-snapshot bugs.

Both take `ENFORCE=<path to android-enforce>` to run against a built binary
(otherwise they `nix build` it).

CI runs the same three things (`shell`, `python-tests`, `nix`) — see
`.github/workflows/ci.yml`.

