# aliyss-android-pkgs

A repository of Android APK packages for Nix: thousands of apps,
each pinned to an exact version, source and hash, buildable with:

```console
$ nix build .#org-videolan-vlc
$ nix build .#org-thoughtcrime-securesms
```

Packages are organized by name, as in nixpkgs: `pkgs/by-name/<shard>/<app-id>/`,
where the shard is the first two characters of the app's publisher label
(`com.spotify.music` -> `by-name/sp/com.spotify.music/`). Every app directory
contains:

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

### Layout

Apps live under `pkgs/by-name/<shard>/<app-id>/`, like nixpkgs' `pkgs/by-name`:
the app id is the directory name and the shard is computed from that name
alone, so seeding an app is one `mkdir` and nothing has to be listed anywhere.

```console
pkgs/by-name/sp/com.spotify.music/{package.nix,hashes.json,verified.json}
pkgs/by-name/th/org.thoughtcrime.securesms/...
```

The shard is the first two characters of the app's **publisher label** — the
label after the TLD: `com.spotify.music` -> `sp`, `org.thoughtcrime.securesms`
-> `th`. Android ids are reverse-DNS, so sharding on the whole id (nixpkgs'
rule) would put every `com.*` id in one `co/` directory: 1881 of the 4199 apps.
Sharding on the publisher label spreads them over 466 directories, the largest
holding 285. A two-label id uses its first label (`a2dp.Vol` -> `a2`), and a
label shorter than two characters falls back to the id (`S.N.A.K.E` -> `sn`).

The rule lives in exactly one place — `scripts/layout.py`, mirrored in
`pkgs/default.nix` — and `tests/test_layout.py` pins it, with the structural
tests asserting that every app directory sits in its own shard. To add an app
by hand, mkdir the two directories and write `package.nix` + `hashes.json`;
`nix build .#<app-id-with-dashes>` picks it up immediately.

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

`-f/--flake` selects the flake to build package names from
(default: the current directory). An app that is **already installed is
skipped** — no rebuild, no reinstall — so the declared list says what
should be present rather than "install now"; pass `--reinstall` to
force an install/update. 
with the local nix, stages the APK under `$HOME` (the Nix store only
exists inside the chroot, while `pm` runs as root outside it),
installs directly with `su -c "pm install -r"` (root), and bounds
the install at 60s so a Google Play Protect block is reported instead
of hanging. App-ids are accepted dotted or dashed; `-u` accepts either too.

### Declarative installs (home-manager module)

The flake also ships a home-manager module
(`homeManagerModules.<system>.default`) that installs the declared apps on
every switch and uninstalls the ones that left the set, so consumers need no
activation script of their own:

```nix
# flake.nix
inputs.aliyss-android-pkgs.url = "github:aliyss/aliyss-android-pkgs";

# home-manager, on the phone host only
home-manager.sharedModules = [
  inputs.aliyss-android-pkgs.homeManagerModules.${system}.default
];

# then declare the apps: the app-id is the key, and what is declared about an
# app goes in its own block
aliyss.androidPkgs = {
  enable = true;
  apps = {
    "com.darkempire78.opencalculator" = { };
    "com.whatsapp".notifications.enabled = true;
  };
};
```

- `apps` is one place per app: the app-id is the key — an app-id that is not a
  key is not installed, and one that leaves the set is uninstalled — and its
  block holds everything declared about it (`permissions`, `notifications`,
  `appops`, `links`, and an optional per-app `mode`). Nothing exists in a second
  map, so an app leaving the phone is one deletion. A plain list of app-ids is
  accepted too, for hosts that want the installs and no state.
- `enable` defaults to `false`, so importing the module in a shared module list
  is harmless on hosts that install nothing.
- `flakePath` (default `~/.config/flake`) is the flake the installer builds app
  attributes from (`android-install -f`); point it elsewhere if your app
  packages live in another flake.
- The module uses the installer package from this same flake, which means the
  input itself must be in scope — passing flake inputs to modules
  (`extraSpecialArgs = inputs`) covers it.
- State lives in `~/.local/state/aliyss-android-pkgs` (the previously installed
  app-ids), which is what makes uninstall-on-removal work.

### Declared app state (permissions, notifications, app ops, links)

`android-install` only puts the APK on the device. The companion
`android-enforce` (`packages.<system>.android-enforce`) makes the app *behave*
the way the config says, on every switch — all of it inside the app's block:

```nix
aliyss.androidPkgs = {
  enable = true;
  apps."com.whatsapp" = {
    # runtime permissions (pm grant / pm revoke)
    permissions = {
      "android.permission.CAMERA" = "deny";
      "android.permission.ACCESS_FINE_LOCATION" = "allow";
    };

    # notification behaviour
    notifications = {
      enabled = false;                            # POST_NOTIFICATIONS
      listeners = [ "com.whatsapp/.NotificationListener" ];
      dnd = true;                                 # exempt from Do Not Disturb
      bubbles = "none";
    };

    # app ops: the toggles Android exposes outside runtime permissions
    # (`appops set`); "default" resets the op to the platform mode
    appops = {
      RUN_ANY_IN_BACKGROUND = "deny";
      REQUEST_INSTALL_PACKAGES = "deny";
    };

    # app links / open by default
    links = {
      open = false;                               # the "Open by default" switch
      domains."wa.me" = "allow";                  # per verified domain
    };
  };
};
```

The config is a set of **overrides**, not a full desired state: an app with an
empty block is untouched, and a permission that is not listed is never granted
or revoked. That makes it safe to mirror what the phone already does:

```console
$ android-enforce --config <config.json> --dump   # current state, as Nix
$ android-enforce --config <config.json> --dump --dump-appops  # + app ops
$ android-enforce --config <config.json> --dump --dump-all     # the whole state
$ android-enforce --config <config.json> --check  # drift report (exit 1)
$ android-enforce --config <config.json> --print-effective  # the config it reads
$ android-enforce --config <config.json>          # apply
```

`--dump` writes the same shape the module takes — one block per app, keyed by
app-id — so the mirror *is* the `apps` declaration. Every declared app is in it
(one with nothing declared is an empty block), which is what keeps feeding the
file back to `apps` from uninstalling the apps it does not mention:

```nix
# generated by `android-enforce --dump-all`
{
  "com.discord" = {
    permissions."android.permission.READ_MEDIA_VISUAL_USER_SELECTED" = "allow";
    notifications.enabled = false;
    appops.RUN_ANY_IN_BACKGROUND = "allow";
    links.open = false;
  };
  "com.github.android".links.domains."github.com" = "allow";
}
```

```nix
# and then, on the phone host
aliyss.androidPkgs.apps = import ./android-app-state.nix;
```

`--dump` prints only what *you* set (`USER_SET` in `dumpsys package`), so
pasting it into the dotfiles and switching applies as a no-op until you change
something. App ops are the exception: the platform reports targetSdk-derived
modes for every app, so they are only dumped on request (`--dump-appops`).

`--dump-all` is the other fidelity: every runtime permission each app holds
(not only the prompts you answered), notifications for every app, and the
Settings-exposed app ops that are explicitly granted. Use it to mirror a device
you are about to manage — applying that dump is a no-op, because it *is* the
phone. With a USER_SET-only mirror, `managed` reads every grant the device made
without a prompt as "not listed" and takes it away.

Implemented: runtime permissions, `notifications.enabled` (via
`POST_NOTIFICATIONS`), `listeners` (`cmd notification allow_listener`),
`dnd`/`bubbles` (`cmd notification allow_dnd` / `set_bubbles`), app ops
(`appops set`) and app links (`pm set-app-links-allowed` /
`pm set-app-links-user-selection`). Every layer except `dnd`/`bubbles` is read
back from the device, so `--check` diffs it; `dnd` and `bubbles` have no
readable shell surface (the state only exists per notification channel in
`dumpsys notification`), so they are applied but reported as unverifiable. A
link domain an app does not declare is reported and fails the switch instead of
silently doing nothing. Not implemented yet: notification channels (the state
lives in `/data/system/notification_policy.xml`, which is read only at boot, and
the live binder path needs a full `NotificationChannel` parcel that
`service call` cannot encode), and per-permission `userFixed` flags
(`pm set-permission-flags`).

### Modes: overrides (default) and managed

`mode` decides how the per-app state is read. The default, `overrides`, treats
the config as additions only. `managed` treats it as the whole intent per app:
whatever is granted but not listed is taken away. An app's own `mode` overrides
the global one, so managed can be rolled out one app at a time:

```nix
aliyss.androidPkgs = {
  enable = true;
  mode = "managed";

  apps = {
    # this one takes its curated block as the baseline
    "com.darkempire78.opencalculator".mode = "recommended";

    "com.whatsapp" = {
      mode = "overrides";                   # keep this one additive
      notifications.enabled = true;
      appops.RUN_ANY_IN_BACKGROUND = "allow";
    };

    "com.example.browser".permissions."android.permission.ACCESS_FINE_LOCATION" = "deny";
  };
};
```

Two carve-outs keep `managed` from being destructive by surprise:

- **POST_NOTIFICATIONS is not part of it.** Notifications stay controlled by
  `notifications.enabled`, so a managed switch does not silently silence every
  app that has no notification entry.
- **Only the app ops Android Settings exposes take part** (background activity,
  install unknown apps, draw over other apps, modify system settings, exact
  alarms, usage access, all-files access). The rest are platform-internal
  behaviour flags — wake locks, audio focus, clipboard, volume — where `deny`
  breaks the app rather than protecting you. `ACCESS_RESTRICTED_SETTINGS` is
  excluded too: it is the switch that lets a sideloaded app use accessibility
  and notification access at all, not a privacy toggle.

`managed` only ever *removes grants*: a permission the app does not hold and an
app op that is unset (i.e. still at its platform default) are left alone. Run
`--dry-run` first — it prints exactly what would be taken away:

```console
$ android-enforce --config <config.json> --dry-run   # what managed would change
$ android-enforce --config <config.json> --check     # drift report, exit 1
```

### Recommended: a curated block per app

`recommended` mode is `managed` with a baseline that ships next to the app: a
`recommended.json` sidecar in `pkgs/by-name/<shard>/<app-id>/` says what that app
*should* be allowed to do, independent of any one phone.

```json
{
  "permissions": { "android.permission.CAMERA": "allow" },
  "appops": { "RUN_ANY_IN_BACKGROUND": "deny" },
  "notifications": { "enabled": true, "bubbles": "none" },
  "links": { "domains": { "wa.me": "allow" } }
}
```

Every key is optional — only what you list is an opinion. Precedence, per app:

1. the consumer's config (the app's block: `permissions` / `appops` /
2. then the app's `recommended.json`,
3. then the mode's default: `recommended` (like `managed`) takes away whatever
   is left unlisted; `overrides` leaves it alone.

An app with no sidecar still works — it falls back to the consumer's config plus
the managed default, and `--check` reports it as uncurated so the gap is visible:

```console
$ android-enforce --config <config.json> --check
warn: com.example.app has no recommended block (47 grants default to deny)
```

`packages.<system>.android-recommended` bundles every sidecar into one index,
which the home-manager module passes to the enforcer as `--recommended`. The
curation therefore travels with the app (and its signer, pin and history)
instead of living in each consumer.

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
