# aliyss-android-pkgs

A repository of Android APK packages for Nix: thousands of apps,
each pinned to an exact version, source and hash, buildable with:

```console
$ nix build .#org-videolan-vlc
$ nix build .#org-thoughtcrime-securesms
```

Packages are organized as `pkgs/<category>/<app-id>/` where every app
directory contains:

| file           | purpose                                                              |
|----------------|----------------------------------------------------------------------|
| `package.nix`  | static template that calls `fetchApk` (reads `./hashes.json`)        |
| `hashes.json`  | generated lockfile: `{version, apkName?, architectures: {system: {archStr, hash}}}` |
| `history.json` | version history, newest first: `{versions: [{version, versionCode, date?, size?}]}` (written by `update.py --history`) |
| `verified.json`| signer certificate fingerprints + attribution (written by the seeders) |

## Sources and the hash model

The same Android app can have **different content per provider**, so the
source is pinned in `package.nix` and every hash in `hashes.json` is specific
to that source. `scripts/update.py` always resolves updates against the
provider recorded in the package, never a different one.

| source                  | how hashes are pinned                                            | hash mode     |
|-------------------------|------------------------------------------------------------------|---------------|
| `apk-pure` (default)    | `apkeep` downloads per architecture; NAR hash of the installed `share/apk` layout (computed by `update.py`) | recursive |
| `f-droid`               | **flat file sha256 straight from the repo's signed index** — no download needed to pin | flat |
| IzzyOnDroid (`f-droid` + `repoUrl`) | same as f-droid, against `https://apt.izzysoft.de/fdroid/repo` | flat |
| `github-releases`       | latest release resolved via the GitHub API; the chosen `.apk` asset is downloaded and hashed flat (GitHub publishes no hashes) | flat |
| `google-play` / `aurora`| needs credentials (`GOOGLE_EMAIL` + `GOOGLE_AUTH_TOKEN`/`GOOGLE_AAS_TOKEN`); version cannot be pinned, requires `--rehash` | recursive |

F-Droid-format indexes (`f-droid.org/repo/index-v1.json`, IzzyOnDroid) are
signed and publish, per APK, the exact file name, its sha256 and the signer
certificate fingerprint — so those apps are pinned fully (version + hash +
signer) **without downloading a single APK**, and `fetchApk` downloads
`<repoUrl>/<apkName>` with `outputHashMode = "flat"` so the index hash *is*
the build hash.

`github-releases` apps (open-source apps that APKPure does not carry, e.g.
Orbot, Bitwarden Authenticator, Dantotsu addons) pin the release tag as the
version and the exact asset name in `hashes.json`; `update.py` resolves the
latest release via the GitHub API, downloads the best `.apk` asset
(universal > arm64-v8a > x86_64 > any) and hashes it flat. `package.nix` pins
the `ghRepo` (`owner/repo`) statically.

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

### Categories

Apps live under `pkgs/<category>/<app-id>/`. `scripts/recategorize.py` assigns
categories from the **curated per-app categories in the F-Droid / IzzyOnDroid
`index-v2.json` indexes** (falling back to keyword heuristics on the app id +
name/summary), so re-run it after seeding:

```console
python scripts/recategorize.py            # consult f-droid.org + IzzyOnDroid
python scripts/recategorize.py --all      # also reconsider non-misc apps
python scripts/recategorize.py --dry-run  # preview only
```

Current taxonomy: `browser`, `camera`, `connectivity`, `development`,
`education`, `finance`, `games`, `graphics`, `health`, `keyboard`, `maps`,
`messaging`, `misc`, `music`, `productivity`, `reading`, `security`, `social`,
`time`, `tools`, `video`, `weather`, `writing`.

## Updating

```console
python scripts/update.py                 # update everything (writes)
python scripts/update.py --check         # only report
python scripts/update.py --only org.thoughtcrime.securesms
python scripts/update.py --rehash        # recompute hashes for pinned versions
python scripts/update.py --history       # fetch per-app version history (history.json)
python scripts/update.py --history --check   # report history changes without writing
```

* apk-pure apps: queries `apkeep -l`, downloads per architecture, hashes and
  rewrites `hashes.json`.
* f-droid / Izzy apps: reads the repo's index (fetched once per repo) and
  pins the new version + flat hash directly — no download.
* github-releases apps: resolves the latest release via the GitHub API and
  pins the best `.apk` asset (version = release tag).
* google-play / aurora apps: skipped unless `--rehash` (credentials via env).

When a downloaded APK's signer does not match `verified.json` (checked with
`apksigner` when available), the update fails. APKPure seeds start with an
empty fingerprint list (APKPure publishes no signing-certificate database);
the first download verified with `apksigner` records the observed
fingerprints into `verified.json`, after which every update re-checks against
them.

## Version history

Every app can carry a `history.json` with its version history, newest first:

```console
python scripts/update.py --history          # all apps
python scripts/update.py --history --only com.Slack
```

* apk-pure apps: fetched from the APKPure `/versions` page (versionCode, date,
  size) and merged with `apkeep -l` (the full list of versions apkeep can
  actually download); apps whose web page is geo-blocked still get the apkeep
  list.
* f-droid / Izzy apps: derived from the repo's signed index (every APK entry),
  so it is complete and free.
* github-releases apps: derived from the GitHub releases API (release tag,
  date, asset size).

Apps with no public source (closed-source apps absent from APKPure, e.g.
Discord, which APKPure lists under a non-numeric "Stable" version) simply keep
an empty history.

The schema is validated by the test suite (`tests/test_repo_structure.py`).

## Installing built apps

Builds produce a single APK: f-droid/Izzy apps **are** the file itself, apk-pure
apps land at `$out/share/apk/<name>.apk`. Install with adb:

```console
$ adb install -r result                       # f-droid / Izzy layout
$ adb install -r result/share/apk/org.videolan.vlc_*.apk   # apk-pure layout
```

Some devices refuse USB installs (`adb install` → `INSTALL_FAILED_USER_RESTRICTED`)
until **Developer options → Install via USB** is enabled; once it is, plain
`adb install` / `adb uninstall` work without root. On rooted devices where the
restriction can't be lifted (or for apps installed into privileged locations),
root `pm` bypasses it — `scripts/install.sh` automates that fallback: it tries
plain `adb` first and retries as root (`su -c 'pm install/uninstall'`) on
failure, resolving the built APK for you:

```console
$ scripts/install.sh com-jjewuz-justweather    # builds + installs, root fallback
$ scripts/install.sh -u com.jjewuz.justweather # uninstalls, root fallback
$ scripts/install.sh -r com-jjewuz-justweather # force the root `pm` path
```

With several devices connected, pick one with `-s <serial>` (or set
`ANDROID_SERIAL`); every adb call is then targeted at that device:

```console
$ scripts/install.sh -s R58M123 com-jjewuz-justweather
$ scripts/install.sh -s R58M123 -u com.jjewuz.justweather
```

The installer is also exposed as a flake package (`packages.<system>.android-install`),
so it runs without a repo checkout — the single install entry point for
consumers (the dotfiles' `aliyss.androidPkgs` home-manager option and the
phone's `install-app` command use it instead of shipping their own installer):

```console
$ nix run .#android-install -- -f . com.darkempire78.opencalculator
$ nix run .#android-install -- -f . -u com.darkempire78.opencalculator
```

`-f/--flake` selects the flake to build package names from (default: the
current directory). On a device with no adb (e.g. Termux), or with
`-d/--on-device`, the script runs **on the device itself**: it builds the APK
with the local nix, maps the chroot store path to the host-visible
`~/.nix/nix` layout, installs directly with `su -c 'pm install -r'` (root), and
bounds the install at 60s so a Google Play Protect block is reported instead
of hanging. App-ids are accepted dotted or dashed; `-u` accepts either too.

## Development

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
ruff format scripts/ tests/         # auto-format
```

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
own provider. CI runs both jobs (`.github/workflows/ci.yml`).

## Trust model & caveats

* The F-Droid index is served over TLS and additionally signed (JAR/GPG via
  `index-v1.jar` / `index-v1.json.asc`) — verify those for maximum trust.
  Hashes pinned from it are covered by that signature, and `update.py`
  re-verifies downloads with `apksigner` when available.
* IzzyOnDroid hosts many proprietary/freeware apps. `fetchApk` defaults to
  `license = "free"`; review `meta.license` before shipping an Izzy package
  set to unfree-only consumers.
* APKPure/Play apps are frequently unfree; the repo's own package set allows
  them (`config.allowUnfree = true`), consumers importing the overlay keep
  nixpkgs' standard gating.
* Per-ABI-only APKs (e.g. arm64-only) are not seeded by default; universal
  seeds build on any Nix system.
