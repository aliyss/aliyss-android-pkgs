# aliyss-android-pkgs

A Nix repository of **Android APKs**, pinned by version, source and hash:
4115 buildable apps today, plus the tooling to keep them honest.

Sibling repo to [aliyss/aliyss-android-settings](https://github.com/aliyss/aliyss-android-settings):
the **packages live here** and the phone's declarative state lives there. A
consumer only ever names an app id — `nix build .#com-darkempire78-opencalculator`
— and this repo resolves that to one exact artifact.

```console
$ nix build .#org-videolan-vlc
$ nix build .#org-thoughtcrime-securesms
```

## How it is organised

Apps live in the **by-name layout**, like nixpkgs' `pkgs/by-name`: the app id *is*
the directory name, and the shard above it follows from that name alone, so
adding an app is one `mkdir` and nothing anywhere lists what exists.

```
pkgs/by-name/sp/com.spotify.music/{package.nix,hashes.json,verified.json}
pkgs/by-name/th/org.thoughtcrime.securesms/...
```

Reverse-DNS ids would put every `com.*` app in one directory, so the shard is
the first two characters of the **publisher** label instead: 4199 apps over 466
shards, the largest holding 285. [docs/layout.md](docs/layout.md) has the rule,
why it is the publisher label, and the invariants that keep it true.

An app directory holds its pin, separated so a version bump is a diff to one
generated file:

| file            | purpose                                                              |
|-----------------|----------------------------------------------------------------------|
| `package.nix`   | static template that calls `fetchApk` (reads `./hashes.json`)        |
| `hashes.json`   | generated lockfile: `{version, apkName?, architectures: {system: {archStr, hash}}}` |
| `history.json`  | version history, newest first: `{versions: [{version, versionCode, date?, size?}]}` |
| `verified.json` | signer certificate fingerprints + attribution (written by the seeders) |
| `recommended.json` | optional curated permission block for `recommended` mode (see below) |

Most apps come from **F-Droid**, whose signed index publishes the exact file name
and sha256 of every APK, so a pin is trustworthy without downloading anything;
`github-releases` and `apk-pure` are also supported. Which source is worth what,
and the trust model, is [docs/sources.md](docs/sources.md).

## The pieces

Beyond the app packages, the flake ships three tools and a module:

- **`android-install`** — gets a built APK onto a device. Builds the package,
  tries plain `adb install`, and falls back to root `pm install` when the device
  refuses USB installs; also runs on the device itself, with no adb at all. Apps
  are idempotent: an already-installed app is skipped, not reinstalled.
- **`android-enforce`** — makes an app *behave* as declared: runtime
  permissions, notification access, app ops and app links, applied with root and
  readable back with `--check`/`--dump`. Everything declared about an app lives
  in that app's block, and `--dump` writes the same shape back, so the phone can
  be mirrored into the config.
- **`android-recommended`** — bundles the `recommended.json` sidecars into the
  index `android-enforce --recommended` reads, so a curated per-app baseline
  travels with the app instead of living in each consumer.
- **the home-manager module** (`homeManagerModules.<system>.default`) — declares
  the apps and their state, installs on every switch and uninstalls what left the
  set.

## Docs

| doc | what it covers |
|-----|----------------|
| [layout.md](docs/layout.md) | the by-name convention, the shard rule, and the fixtures that keep it honest |
| [sources.md](docs/sources.md) | where pins come from, what each hash proves, trust model and caveats |
| [updating.md](docs/updating.md) | bumping pins and version history, `--check`/`--dry-run`, the daily update PR |
| [installing.md](docs/installing.md) | `install.sh`, adb vs root, the declarative home-manager installs |
| [enforce.md](docs/enforce.md) | declared app state, `overrides` vs `managed`, curated `recommended` blocks |
| [development.md](docs/development.md) | seeding, the ruff/mypy/pytest gates, and what `nix flake check` runs |

## Testing

Nothing here needs a device: the suite is offline and the structural tests walk
the real tree.

```console
nix flake check        # the whole gate: shell lint, ruff + mypy + pytest, config shapes
pytest tests/          # just the test suite
```

## Repo layout

```
pkgs/by-name/<shard>/<app-id>/   one directory per app (package.nix + sidecars)
pkgs/default.nix                 walks the tree into the package set
lib/fetchApk.nix                 fixed-output APK fetch (apkeep or direct URL)
lib/recommended.nix              bundles the recommended.json sidecars
scripts/layout.py                the by-name rule; every other path goes through it
scripts/seed_*.py, update.py     seeders, and the pin updater
scripts/install.sh, enforce.sh   the two device-facing tools
home-manager-module.nix          declarative installs + state
tests/                           offline suite (unit + structural invariants)
docs/                            layout, sources, updating, installing, enforce, development
```

## License

MIT — see [LICENSE](LICENSE).
