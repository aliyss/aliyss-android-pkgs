#!/usr/bin/env bash
# Install / uninstall APKs built from this repo on an Android device.
#
# Two modes:
#
#   adb mode (default when `adb` is on PATH): the desktop/USB workflow.
#     `adb install -r` with an automatic root `pm` fallback — many devices
#     refuse USB/shell installs ("Install via USB" developer option off, or a
#     device policy setting DISALLOW_INSTALL_APPS), so `adb install` fails with
#     INSTALL_FAILED_USER_RESTRICTED while `adb shell su -c 'pm install ...'`
#     (root) succeeds. Uninstall works the same way.
#
#   on-device mode (default when `adb` is missing, or with -d/--on-device):
#     run directly on the device itself (e.g. inside Termux, possibly through
#     the nix-chroot). The APK is built with the local nix and installed with
#     `su -c 'pm install -r'` — no adb involved. The dotfiles home-manager
#     module (aliyss.androidPkgs) and the phone's install-app command use this
#     mode.
#
# Usage:
#   scripts/install.sh <pkg-or-path>              install a built package
#   scripts/install.sh -u <app-id>                uninstall an app
#   scripts/install.sh -s <serial> <pkg-or-path>  pick a device among several
#   scripts/install.sh -r <pkg-or-path>           force the root `pm` path
#   scripts/install.sh -d -f <flake> <app-id>     on-device, build from a flake
#
# <pkg-or-path> is either an app-id / flake package name (e.g.
# com.darkempire78.opencalculator or com-darkempire78-opencalculator, built with
# `nix build <flake>#<attr>` first) or a path to a built result / .apk file.
set -euo pipefail

MODE=install
ROOT_ONLY=0
ON_DEVICE=0
APP_ID=""
TARGET=""
# Every positional target (the declarative list passes many app-ids at once).
TARGETS=()
# Reinstall even when the app is already present (normally it is skipped).
REINSTALL=0
SERIAL=""
# Flake to build package names from (default: the current directory's flake).
FLAKE="."
# All adb invocations go through this; -s/--serial appends the device pick.
ADB=(adb)

usage() {
  cat <<'EOF'
Usage:
  scripts/install.sh [options] <pkg-or-path>   install a built APK
  scripts/install.sh [options] -u <app-id>     uninstall an app

Arguments:
  <pkg-or-path>  app-id / flake package name (e.g. com-jjewuz-justweather) or a
                 path to a built result directory / .apk file

Options:
  -d, --on-device    run on the device itself (no adb): build + su 'pm install'
  -f, --flake <ref>  flake to build package names from (default: current dir)
  -s, --serial <serial>    adb device serial (default: $ANDROID_SERIAL, or the
                           only connected device)
  -u, --uninstall <app-id>   uninstall instead of install
  -r, --root                 only use the root `pm` path (no plain adb attempt)
      --reinstall            reinstall an app that is already installed
                             (by default an installed app is skipped)
  -h, --help                 show this help
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h | --help)
        usage
        exit 0
        ;;
      -d | --on-device)
        ON_DEVICE=1
        shift
        ;;
      -f | --flake)
        shift
        if [[ $# -eq 0 ]]; then
          echo "error: -f/--flake needs a flake reference" >&2
          exit 2
        fi
        FLAKE="$1"
        shift
        ;;
      -s | --serial | --device)
        shift
        if [[ $# -eq 0 ]]; then
          echo "error: -s/--serial needs a device serial" >&2
          exit 2
        fi
        SERIAL="$1"
        ADB+=( -s "$SERIAL" )
        shift
        ;;
      -u | --uninstall)
        MODE=uninstall
        shift
        if [[ $# -eq 0 ]]; then
          echo "error: -u/--uninstall needs an app id" >&2
          exit 2
        fi
        APP_ID="$1"
        shift
        ;;
      -r | --root)
        ROOT_ONLY=1
        shift
        ;;
      --reinstall)
        REINSTALL=1
        shift
        ;;
      --)
        shift
        break
        ;;
      -*)
        echo "error: unknown option: $1" >&2
        usage >&2
        exit 2
        ;;
      *)
        break
        ;;
    esac
  done
  TARGETS=("$@")
  TARGET="${TARGETS[0]:-}"
}

# app-id <-> flake attr. Mirror pkgs/default.nix sanitizeName: dots -> dashes,
# and prefix "pkg-" for app-ids that start with a digit (illegal Nix attr
# names). Android package names never contain dashes, so the reverse always
# recovers the real app-id.
to_attr() {
  local s="${1//./-}"
  case "$s" in
    [0-9]*) printf 'pkg-%s\n' "$s" ;;
    *) printf '%s\n' "$s" ;;
  esac
}
to_app_id() {
  local s="${1#pkg-}"
  printf '%s\n' "${s//-/}"
}

# The `su` used for on-device pm. Prefer the PATH `su`: on Termux this is a
# small shim that locates /system/bin/su AND sets the root-context PATH
# (including /system/bin) that `pm` needs to resolve its internal `cmd` call.
# Fall back to the shim's absolute path for contexts with a minimal PATH (the
# home-manager activation inside the nix-chroot has no $PREFIX/bin).
#
# A candidate has to be *probed*, not trusted by name: inside the nix chroot the
# real su is hidden (/system/bin/su and /data/adb are not mounted) and
# $PREFIX/bin/su — which IS on PATH there — is a stub that only prints "No su
# program found". Where nothing elevates, KernelSU's ksud CLI is the way in
# (libksud.so is a plain file under $HOME), wrapped in a `su -c`-compatible shim
# so the call sites below stay untouched.
SU="$(command -v su 2>/dev/null || true)"
KSUD_LIB="${KSUD_LIB:-$HOME/sukisu-mgr/lib/arm64-v8a/libksud.so}"
KSUD_LINKER="${KSUD_LINKER:-/system/bin/linker64}"

# `</dev/null` keeps a desktop su (util-linux) from prompting for a password and
# hanging: with no tty it fails immediately instead.
su_elevates() { # $1 = candidate
  [[ "$("$1" -c 'id -u' 2>/dev/null </dev/null)" == "0" ]]
}

# `su -c` shim over libksud.so, regenerated when its body changes (bump rev) or
# when the libksud path moves (a SukiSU update can relocate it). Lives in
# aliyss-android-pkgs.d/ because ~/.local/state/aliyss-android-pkgs is the
# module's *file* of already-installed app-ids.
ksud_shim() {
  local shim="$HOME/.local/state/aliyss-android-pkgs.d/su-ksud" rev=1
  if [[ ! -x "$shim" ]] || ! grep -q "shim-rev=$rev" "$shim" 2>/dev/null \
    || ! grep -qF "$KSUD_LIB" "$shim" 2>/dev/null; then
    mkdir -p "$(dirname "$shim")" || return 1
    cat >"$shim" <<EOF
#!/data/data/com.termux/files/usr/bin/sh
# Generated by android-install — do not edit (shim-rev=$rev).
# su -c 'cmd' over KernelSU's ksud CLI, for hosts where the real su is not
# reachable (inside the Nix chroot). Commands are read on stdin, -g selects the
# global mount namespace, and the last command's exit status is propagated.
# PATH must hold the Android system dirs: ksud runs the command through a shell
# it resolves on PATH, and a bare home-manager activation PATH has neither sh
# nor pm ("No such file or directory" otherwise).
PATH=/system/bin:/system/xbin:/vendor/bin
export PATH
[ "\${1:-}" = "-c" ] && shift
printf '%s\n' "\$*" | "$KSUD_LINKER" "$KSUD_LIB" debug su -g
EOF
    chmod 700 "$shim" || return 1
  fi
  printf '%s' "$shim"
}

SU_OK=0
[[ -n "$SU" ]] && su_elevates "$SU" && SU_OK=1
if [[ "$SU_OK" == 0 ]]; then
  for candidate in /system/bin/su /system/xbin/su /sbin/su; do
    if [[ -x "$candidate" ]] && su_elevates "$candidate"; then
      SU="$candidate"
      SU_OK=1
      break
    fi
  done
fi

# Is the app already installed? Asked through the same su the install
# would use, so no build/APK resolution is involved.
app_installed() { # $1 = app-id
  local out
  out="$("$SU" -c "/system/bin/pm list packages '$1'" 2>/dev/null || true)"
  [[ "$out" == *"package:$1"* ]]
}
if [[ "$SU_OK" == 0 && -x "$KSUD_LINKER" && -f "$KSUD_LIB" ]]; then
  shim="$(ksud_shim)" || shim=""
  if [[ -n "$shim" ]]; then
    SU="$shim"
    SU_OK=1
  fi
fi
if [[ "$SU_OK" == 0 && -z "$SU" ]]; then
  # Minimal-PATH context with nothing usable: keep the Termux shim's absolute
  # path so a missing root grant still fails per-app, not here.
  SU="/data/data/com.termux/files/usr/bin/su"
fi

check_adb() {
  command -v adb >/dev/null 2>&1 || {
    echo "error: 'adb' not found on PATH" >&2
    exit 1
  }
  if [[ -n "$SERIAL" ]]; then
    # A serial was requested explicitly: it must be present and online.
    if ! "${ADB[@]}" devices \
      | awk -v s="$SERIAL" 'NR > 1 && $2 == "device" && $1 == s { found = 1 } END { exit !found }'; then
      echo "error: device '$SERIAL' not connected (check 'adb devices')" >&2
      exit 1
    fi
    return
  fi
  local n
  n="$("${ADB[@]}" devices | awk 'NR > 1 && $2 == "device" { n++ } END { print n + 0 }')"
  if [[ "$n" -eq 0 ]]; then
    echo "error: no Android device connected (check 'adb devices')" >&2
    exit 1
  fi
  if [[ "$n" -gt 1 && -z "${ANDROID_SERIAL:-}" ]]; then
    echo "error: multiple devices connected; use -s/--serial or set ANDROID_SERIAL" >&2
    exit 1
  fi
}

# Print the single APK file to install for a built result path.
resolve_apk() {
  local p="$1" f
  if [[ -f "$p" ]]; then
    echo "$p"
    return 0
  fi
  if [[ -d "$p" ]]; then
    # apk-pure layout: $out/share/apk/<file>.apk (.xapk)
    if [[ -d "$p/share/apk" ]]; then
      f="$(find "$p/share/apk" -maxdepth 1 -type f -print -quit 2>/dev/null)"
      if [[ -n "$f" ]]; then
        echo "$f"
        return 0
      fi
    fi
    f="$(find "$p" -maxdepth 3 -type f \( -name '*.apk' -o -name '*.xapk' \) -print -quit 2>/dev/null)"
    if [[ -n "$f" ]]; then
      echo "$f"
      return 0
    fi
  fi
  return 1
}

# Build the package if given a flake attribute name, then resolve its APK.
resolve_target() {
  local arg="$1" out attr
  if [[ "$arg" == */* ]] || [[ -e "$arg" ]]; then
    resolve_apk "$arg"
  else
    attr="$(to_attr "$arg")"
    out="$(nix build --no-link --print-out-paths "$FLAKE#$attr")" || {
      echo "error: 'nix build $FLAKE#$attr' failed (flake package not found?)" >&2
      return 1
    }
    resolve_apk "$out"
  fi
}

# pm install runs as root in Android's namespace, where the Nix store is not
# visible: it lives inside the nix-chroot rootfs at ~/.nix/nix (bind-mounted at
# /nix inside the chroot), so handing pm a /nix/store path fails with
# "Can't open file: /nix/store/...". Stage the APK under $HOME — the same
# absolute path inside and outside the chroot, and readable by root — the way
# the adb path stages into /data/local/tmp.
stage_apk() {
  local p="$1" stage="$HOME/.cache/android-install-staging" dest
  mkdir -p "$stage" || return 1
  dest="$stage/$(basename "$p")"
  if [[ "$p" != "$dest" ]]; then
    cp -f "$p" "$dest" || return 1
  fi
  printf '%s\n' "$dest"
}

# pm install runs through system_server, which can block indefinitely on a
# Google Play Protect dialog (new or flagged APKs — e.g. apps built for an
# older Android). Run it in the background and poll briefly; if it hasn't
# finished, report what is blocking it and give up (the background process
# stays parked until the dialog is answered, then exits on its own). The
# dialog is left up on purpose — allowing the app is the user's Play Protect
# decision.
on_device_install() {
  local apk="$1" log marker waited status
  apk="$(stage_apk "$apk")"
  if [[ ! -r "$apk" ]]; then
    echo "error: cannot read built APK at $apk" >&2
    return 1
  fi
  # An APK is a zip archive — sanity-check the magic bytes before installing.
  if [[ "$(head -c 2 "$apk")" != "PK" ]]; then
    echo "error: built output is not an APK (zip): $apk" >&2
    return 1
  fi
  log="$HOME/.cache/install-android-pkgs.log"
  marker="$log.exit"
  rm -f "$log" "$marker"
  # Detached subshell so a blocked pm can never wedge the script's own stdout
  # or pid-tracking; completion is signalled by a marker file instead of wait.
  # The subshell's stdout is discarded (pm writes to $log inside it).
  (
    "$SU" -c "/system/bin/pm install -r '$apk'" >"$log" 2>&1
    printf '%s\n' "$?" >"$marker"
  ) </dev/null >/dev/null 2>&1 &
  waited=0
  while [[ ! -f "$marker" ]] && [[ "$waited" -lt 60 ]]; do
    sleep 2
    waited=$((waited + 2))
  done

  if [[ ! -f "$marker" ]]; then
    # Still running: almost certainly waiting on a Play Protect dialog.
    if "$SU" -c "/system/bin/dumpsys window" 2>/dev/null | grep -qE "PlayProtect|packageinstaller"; then
      echo "!! blocked by Google Play Protect (older/flagged APK) — allow it in Play Protect on the device, or pick another app" >&2
    else
      echo "!! install is still running — check the device screen" >&2
    fi
    return 1
  fi

  status="$(cat "$marker")"
  if [[ "$status" -ne 0 ]]; then
    cat "$log" >&2
  fi
  return "$status"
}

root_install() {
  local apk="$1" remote
  remote="/data/local/tmp/$(basename "$apk")"
  echo "> ${ADB[*]} push \"$apk\" $remote"
  "${ADB[@]}" push "$apk" "$remote" >/dev/null 2>&1 || {
    echo "error: adb push failed" >&2
    exit 1
  }
  echo "> ${ADB[*]} shell \"su -c 'pm install -r $remote'\""
  if "${ADB[@]}" shell "su -c 'pm install -r $remote'"; then
    echo "OK: installed as root via pm"
  else
    echo "error: root 'pm install' failed (is su/Magisk set up?)" >&2
    "${ADB[@]}" shell "rm -f $remote" >/dev/null 2>&1 || true
    exit 1
  fi
  "${ADB[@]}" shell "rm -f $remote" >/dev/null 2>&1 || true
}

install_apk() {
  local apk="$1"
  if [[ "$apk" == *.xapk ]]; then
    echo "error: '$apk' is a split .xapk bundle; 'pm install' cannot install it directly." >&2
    echo "Install the splits with 'adb install-multiple' or a store client." >&2
    exit 1
  fi
  if [[ "$ON_DEVICE" == 1 ]]; then
    if on_device_install "$apk"; then
      echo "OK: installed"
    else
      exit 1
    fi
    return
  fi
  if [[ "$ROOT_ONLY" == 1 ]]; then
    root_install "$apk"
    return
  fi
  echo "> ${ADB[*]} install -r \"$apk\""
  if "${ADB[@]}" install -r "$apk"; then
    echo "OK: installed via adb"
  else
    echo "adb install failed (INSTALL_FAILED_USER_RESTRICTED?) — retrying as root" >&2
    root_install "$apk"
  fi
}

on_device_uninstall() {
  local app_id="$1"
  "$SU" -c "/system/bin/pm uninstall $app_id"
}

root_uninstall() {
  local app_id="$1"
  echo "> ${ADB[*]} shell \"su -c 'pm uninstall $app_id'\""
  "${ADB[@]}" shell "su -c 'pm uninstall $app_id'"
}

uninstall_app() {
  local app_id="$1"
  if [[ "$ON_DEVICE" == 1 ]]; then
    on_device_uninstall "$app_id"
    return
  fi
  if [[ "$ROOT_ONLY" == 1 ]]; then
    root_uninstall "$app_id"
    return
  fi
  echo "> ${ADB[*]} uninstall $app_id"
  if "${ADB[@]}" uninstall "$app_id"; then
    echo "OK: uninstalled via adb"
  else
    echo "adb uninstall failed — retrying as root" >&2
    root_uninstall "$app_id"
  fi
}

main() {
  parse_args "$@"
  # On a device with no adb (e.g. Termux) there is nothing to talk to — run
  # the build + pm install directly on the device instead.
  if [[ "$ON_DEVICE" == 0 ]] && ! command -v adb >/dev/null 2>&1; then
    ON_DEVICE=1
  fi
  if [[ "$ON_DEVICE" == 0 ]]; then
    check_adb
  fi
  if [[ "$MODE" == uninstall ]]; then
    if [[ -z "$APP_ID" ]]; then
      echo "error: -u/--uninstall needs an app id" >&2
      exit 2
    fi
    uninstall_app "$(to_app_id "$APP_ID")"
  else
    if [[ -z "$TARGET" ]]; then
      usage >&2
      exit 2
    fi
    local target id apk
    for target in "${TARGETS[@]}"; do
      [[ -z "$target" ]] && continue
      # On the phone the declared list says which apps should be present,
      # not "install right now": an app that is already installed is left
      # alone — no rebuild, no reinstall. --reinstall forces it (e.g. to move
      # to a newly pinned version).
      if [[ "$ON_DEVICE" == 1 && "$REINSTALL" == 0 && "$target" != */* ]]; then
        id="$(to_app_id "$target")"
        if app_installed "$id"; then
          echo "already installed: $id"
          continue
        fi
      fi
      apk="$(resolve_target "$target")" || exit $?
      if [[ -z "$apk" ]]; then
        echo "error: no .apk found in '$target'" >&2
        exit 1
      fi
      install_apk "$apk"
    done
  fi
}

main "$@"
