#!/usr/bin/env bash
# Install / uninstall APKs built from this repo on a connected Android device.
#
# Why the root fallback: many devices refuse USB/shell installs ("Install via
# USB" developer option off, or a device policy setting DISALLOW_INSTALL_APPS),
# so `adb install` fails with INSTALL_FAILED_USER_RESTRICTED while
# `adb shell su -c 'pm install ...'` (root) succeeds. This script tries the
# normal `adb` path first and falls back to root `pm` automatically; uninstall
# works the same way. On a rooted device the restriction can also be lifted
# once via Developer options -> Install via USB, making plain adb enough.
#
# Usage:
#   scripts/install.sh <pkg-or-path>              install a built package
#   scripts/install.sh -u <app-id>                uninstall an app
#   scripts/install.sh -s <serial> <pkg-or-path>  pick a device among several
#   scripts/install.sh -r <pkg-or-path>           force the root `pm` path
#
# <pkg-or-path> is either a flake package name (e.g. com-jjewuz-justweather,
# which gets built with `nix build .#<name>` first) or a path to a built
# result / .apk file.
set -euo pipefail

MODE=install
ROOT_ONLY=0
APP_ID=""
TARGET=""
SERIAL=""
# All adb invocations go through this; -s/--serial appends the device pick.
ADB=(adb)

usage() {
  cat <<'EOF'
Usage:
  scripts/install.sh [options] <pkg-or-path>   install a built APK
  scripts/install.sh [options] -u <app-id>     uninstall an app

Arguments:
  <pkg-or-path>  flake package name (e.g. com-jjewuz-justweather) or a path
                 to a built result directory / .apk file

Options:
  -s, --serial <serial>    adb device serial (default: $ANDROID_SERIAL, or the
                           only connected device)
  -u, --uninstall <app-id>   uninstall instead of install
  -r, --root                 only use the root `pm` path (no plain adb attempt)
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
  TARGET="${1:-}"
}

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
  local arg="$1" out
  if [[ "$arg" == */* ]] || [[ -e "$arg" ]]; then
    resolve_apk "$arg"
  else
    out="$(nix build --no-link --print-out-paths ".#$arg")" || {
      echo "error: 'nix build .#$arg' failed (flake package not found?)" >&2
      return 1
    }
    resolve_apk "$out"
  fi
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

root_uninstall() {
  local app_id="$1"
  echo "> ${ADB[*]} shell \"su -c 'pm uninstall $app_id'\""
  "${ADB[@]}" shell "su -c 'pm uninstall $app_id'"
}

uninstall_app() {
  local app_id="$1"
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
  check_adb
  if [[ "$MODE" == uninstall ]]; then
    if [[ -z "$APP_ID" ]]; then
      echo "error: -u/--uninstall needs an app id" >&2
      exit 2
    fi
    uninstall_app "$APP_ID"
  else
    if [[ -z "$TARGET" ]]; then
      usage >&2
      exit 2
    fi
    local apk
    apk="$(resolve_target "$TARGET")" || exit $?
    if [[ -z "$apk" ]]; then
      echo "error: no .apk found in '$TARGET'" >&2
      exit 1
    fi
    install_apk "$apk"
  fi
}

main "$@"
