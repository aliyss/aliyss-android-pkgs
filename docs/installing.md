# Installing built apps

Getting a built APK onto a device — by hand over adb, or declaratively through
the home-manager module so a switch is the whole story.

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
force an install/update. On the device itself (the phone's `install-app`, or
`nix run` inside Termux) the same installer builds with the local nix, stages
the APK under `$HOME` (the Nix store only
exists inside the chroot, while `pm` runs as root outside it),
installs directly with `su -c "pm install -r"` (root), and bounds
the install at 60s so a Google Play Protect block is reported instead
of hanging. App-ids are accepted dotted or dashed; `-u` accepts either too.

## Declarative installs (home-manager module)

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

