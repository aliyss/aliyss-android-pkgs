#!/usr/bin/env bash
# Enforce declarative per-app Android state (runtime permissions + notifications)
# from a JSON config, with root. install.sh gets the APK onto the device; this
# makes the app behave the way the config says on every switch.
#
# Usage:
#   scripts/enforce.sh --config <config.json>              # apply
#   scripts/enforce.sh --config <config.json> --check      # drift report, exit 1
#   scripts/enforce.sh --config <config.json> --dry-run    # print commands only
#   scripts/enforce.sh --config <config.json> --dump       # current state as Nix
#   scripts/enforce.sh --config <config.json> --dump --dump-appops   # + app ops
#   scripts/enforce.sh --config <config.json> --only com.app
#   scripts/enforce.sh -s <serial> --config <config.json>  # adb instead of on-device
#
# Config shape (the home-manager module renders this from aliyss.androidPkgs):
#
#   { "apps": ["com.app"],                    # the declared/managed app-ids
#     "permissions": {
#       "com.app": { "android.permission.CAMERA": "allow" }     # or "deny"
#     },
#     "notifications": {
#       "com.app": {
#         "enabled": false,                   # POST_NOTIFICATIONS granted/revoked
#         "listeners": ["com.app/.Listener"], # notification-access components
#         "dnd": true,                        # exempt from Do Not Disturb
#         "bubbles": "none"                   # none | all | selected
#       }
#     },
#     "appops": {
#       "com.app": { "RUN_ANY_IN_BACKGROUND": "allow" }
#     },                                      # allow | deny | ignore | foreground | default
#     "links": {
#       "com.app": {
#         "open": false,                      # open-by-default ("link handling allowed")
#         "domains": { "wa.me": "allow" }     # allow | deny, per verified domain
#       }
#     }
#   }
#
# Semantics: the config holds *overrides*, not a full desired state. An app with
# no entry is untouched, an unlisted permission/op/domain is never touched, and
# `listeners` is scoped to that app's own components. So dumping the current
# state (`--dump`) and feeding it back is a no-op — exactly what you want when
# the dotfiles mirror what the phone already does.
#
# Layers implemented:
#   * runtime permissions  `permissions.<app>."<perm>"`      pm grant / pm revoke
#   * notifications        `notifications.<app>.{enabled,listeners,dnd,bubbles}`
#   * app ops              `appops.<app>.<OP>`               appops set
#   * open-by-default      `links.<app>.open`                pm set-app-links-allowed
#   * link domains         `links.<app>.domains.<domain>`    pm set-app-links-user-selection
#
# Not implemented: notification channels (no shell-encodable state).
#
# `dnd` and `bubbles` have no readable shell surface (the state lives in
# `dumpsys notification`, which only exposes it per notification channel), so
# they are applied but not diffed: `--check` reports them as unverifiable.
set -euo pipefail

# $PREFIX is a Termux-shell concept: inside the nix chroot (home-manager
# activation) it is unset, so default to the standard Termux prefix.
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"

MODE=apply
ON_DEVICE=0
ONLY=""
CONFIG=""
SERIAL="${ANDROID_SERIAL:-}"
FAILED=0
DRIFT=0
DUMP_APP_OPS=0

usage() {
  sed -n '2,/^#   scripts\/enforce\.sh -s <serial>/p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      CONFIG="$2"
      shift 2
      ;;
    --check)
      MODE=check
      shift
      ;;
    --dry-run)
      MODE=dry-run
      shift
      ;;
    --dump)
      MODE=dump
      shift
      ;;
    --dump-appops)
      DUMP_APP_OPS=1
      shift
      ;;
    --only)
      ONLY="$2"
      shift 2
      ;;
    -d | --on-device)
      ON_DEVICE=1
      shift
      ;;
    -s | --serial)
      SERIAL="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$CONFIG" ]]; then
  echo "error: --config <config.json> is required" >&2
  exit 2
fi
if [[ ! -r "$CONFIG" ]]; then
  echo "error: cannot read config: $CONFIG" >&2
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required (the android-enforce package bundles it)" >&2
  exit 2
fi

# --- transport -------------------------------------------------------------
# adb mode for a desktop/another device; on-device mode runs `su -c` directly.
# A device with no adb (e.g. Termux) falls back to on-device.
ADB=()
if [[ "$ON_DEVICE" == 0 ]] && command -v adb >/dev/null 2>&1; then
  ADB=(adb)
  if [[ -n "$SERIAL" ]]; then
    ADB+=(-s "$SERIAL")
  fi
fi

KSUD_LIB="${KSUD_LIB:-$HOME/sukisu-mgr/lib/arm64-v8a/libksud.so}"
KSUD_LINKER="${KSUD_LINKER:-/system/bin/linker64}"

# `</dev/null` keeps a desktop su (util-linux) from prompting for a password.
su_elevates() { # $1 = candidate
  [[ "$("$1" -c 'id -u' 2>/dev/null </dev/null)" == "0" ]]
}

# `su -c` shim over libksud.so, for hosts where the real su is not reachable
# (inside the Nix chroot). Same shim and rev as install.sh, so the two share one
# generated file.
ksud_shim() {
  local shim="$HOME/.local/state/aliyss-android-pkgs.d/su-ksud" rev=1
  if [[ ! -x "$shim" ]] || ! grep -q "shim-rev=$rev" "$shim" 2>/dev/null \
    || ! grep -qF "$KSUD_LIB" "$shim" 2>/dev/null; then
    mkdir -p "$(dirname "$shim")" || return 1
    cat >"$shim" <<EOF
#!/data/data/com.termux/files/usr/bin/sh
# Generated by android-install/android-enforce — do not edit (shim-rev=$rev).
PATH=/system/bin:/system/xbin:/vendor/bin
export PATH
[ "\${1:-}" = "-c" ] && shift
printf '%s\n' "\$*" | "$KSUD_LINKER" "$KSUD_LIB" debug su -g
EOF
    chmod 700 "$shim" || return 1
  fi
  printf '%s' "$shim"
}

SU="$(command -v su 2>/dev/null || true)"
SU_OK=0
if [[ ${#ADB[@]} -eq 0 ]]; then
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
  if [[ "$SU_OK" == 0 && -x "$KSUD_LINKER" && -f "$KSUD_LIB" ]]; then
    shim="$(ksud_shim)" || shim=""
    if [[ -n "$shim" ]]; then
      SU="$shim"
      SU_OK=1
    fi
  fi
  if [[ "$SU_OK" == 0 ]]; then
    echo "error: no working su found (KernelSU/Magisk required for permissions)" >&2
    exit 1
  fi
fi

run_root() { # $1 = command (only app-ids/permissions/components are interpolated)
  if [[ ${#ADB[@]} -gt 0 ]]; then
    "${ADB[@]}" shell "su -c '$1'"
  else
    "$SU" -c "$1"
  fi
}

# --- live state ------------------------------------------------------------
# `dumpsys package` lists every runtime permission with its grant state; the
# trailing flags say whether the *user* set it (USER_SET), which is what --dump
# mirrors: the choices you made, not the OS defaults.
live_runtime_perms() { # $1 = app-id -> "perm granted flags"
  run_root "dumpsys package '$1'" 2>/dev/null \
    | sed -n '/runtime permissions:/,/^$/p' \
    | sed -n 's/^ *\([a-zA-Z0-9_.]*\): granted=\(true\|false\), flags=\[\(.*\)\]$/\1 \2 \3/p' || true
}

live_grant() { # $1 = app-id, $2 = permission -> true|false|(empty)
  live_runtime_perms "$1" | awk -v p="$2" '$1 == p { print $2; exit }'
}

user_set_perms() { # $1 = app-id -> "perm granted" for user-set permissions only
  live_runtime_perms "$1" | awk '$3 ~ /USER_SET/ { print $1, $2 }'
}

live_listeners() { # enabled notification listeners, colon-separated
  run_root "settings get secure enabled_notification_listeners" 2>/dev/null | tr -d '\r' || true
}

app_listeners() { # $1 = app-id -> its enabled listener components
  live_listeners | tr ':' '\n' | grep -F "$1/" || true
}

# `appops get <app> <OP>` answers with "<OP>: <mode>" when the op is set and
# "Default mode: <mode>" when it is not, so both are read here: an unset op is
# equivalent to its default, and --check compares against that.
live_appop() { # $1 = app-id, $2 = OP -> mode or (empty)
  run_root "appops get '$1' '$2'" 2>/dev/null \
    | sed -n "s/^\(Uid mode: \)\?$2: \(allow\|deny\|ignore\|foreground\|default\).*/\2/p" \
    | head -1 || true
}

appop_default() { # $1 = app-id, $2 = OP -> the op's default mode or (empty)
  run_root "appops get '$1' '$2'" 2>/dev/null \
    | sed -n 's/^Default mode: \(allow\|deny\|ignore\|foreground\|default\)$/\1/p' \
    | head -1 || true
}

# Every statically configured op (no runtime telemetry) minus the ops that only
# mirror a runtime permission — those are the `permissions` block's job, and
# appops reports them for every app based on its targetSdk.
live_appop_modes() { # $1 = app-id -> "OP mode"
  local perms
  perms="$(live_runtime_perms "$1" | awk '{ print $1 }' | sed 's/.*\.//')"
  run_root "appops get '$1'" 2>/dev/null | awk '
    /^[A-Z0-9_]+: / {
      if ($0 ~ /time=/) next          # touched at runtime, not configuration
      op = $1; sub(/:$/, "", op)
      mode = $2; sub(/;.*/, "", mode)
      print op, mode
    }' | while read -r op mode; do
    local keep=1 p a b
    a="$(printf '%s' "$op" | sed 's/S$//')"
    for p in $perms; do
      b="$(printf '%s' "$p" | sed 's/S$//')"
      [[ "$a" == "$b" ]] && keep=0
    done
    [[ "$keep" == 1 ]] && printf '%s %s\n' "$op" "$mode"
  done
}

live_link_allowed() { # $1 = app-id -> true|false|(empty)
  run_root "pm get-app-links --user 0 '$1'" 2>/dev/null \
    | sed -n 's/^ *Verification link handling allowed: \(true\|false\)$/\1/p' \
    | head -1 || true
}

live_link_state() { # $1 = app-id -> "domain enabled|disabled"
  run_root "pm get-app-links --user 0 '$1'" 2>/dev/null | awk -v app="$1" '
    { gsub(/\r/, "") }
    /^ *Selection state:/ { insel = 1; st = ""; next }
    !insel { next }
    /^ *Enabled:/ { st = "enabled"; next }
    /^ *Disabled:/ { st = "disabled"; next }
    /^ {10,}[A-Za-z0-9._-]+$/ { if (st != "") print $1, st; next }
    /^ {0,8}[^ ]/ { insel = 0 }
  '
}

declared_link_domains() { # $1 = app-id -> domains the app declares in its manifest
  run_root "pm get-app-links --user 0 '$1'" 2>/dev/null \
    | sed -n '/Domain verification state:/,/^ *User /p' \
    | sed -n 's/^ *\([A-Za-z0-9._-]*\): .*/\1/p' || true
}

# --- config access ---------------------------------------------------------
cfg_apps() {
  jq -r '.apps[]? // empty' "$CONFIG"
}

managed_apps() { # union of apps that have any per-app entry
  { jq -r '.permissions // {} | keys[]?' "$CONFIG"
    jq -r '.notifications // {} | keys[]?' "$CONFIG"
    jq -r '.appops // {} | keys[]?' "$CONFIG"
    jq -r '.links // {} | keys[]?' "$CONFIG"; } | sort -u
}

cfg_perms() { # $1 = app-id -> "perm action"
  jq -r --arg a "$1" '(.permissions // {})[$a] // {} | to_entries[] | "\(.key) \(.value)"' "$CONFIG"
}

notif_field() { # $1 = app-id, $2 = field -> value or "null"
  jq -r --arg a "$1" --arg f "$2" \
    '(.notifications // {})[$a][$f] | if . == null then "null" else tostring end' "$CONFIG"
}

notif_listeners() { # $1 = app-id -> desired components
  jq -r --arg a "$1" '((.notifications // {})[$a].listeners // [])[]' "$CONFIG"
}

cfg_appops() { # $1 = app-id -> "OP mode" (op names are validated: they reach sed)
  jq -r --arg a "$1" \
    '((.appops // {})[$a] // {}) | to_entries[] | select(.key | test("^[A-Z0-9_]+$")) | "\(.key) \(.value)"' \
    "$CONFIG"
}

link_open() { # $1 = app-id -> true|false|null
  jq -r --arg a "$1" '(.links // {})[$a].open | if . == null then "null" else tostring end' "$CONFIG"
}

link_entries() { # $1 = app-id -> "domain allow|deny"
  jq -r --arg a "$1" '((.links // {})[$a].domains // {}) | to_entries[] | "\(.key) \(.value)"' "$CONFIG"
}

# --- actions ---------------------------------------------------------------
log() { printf '%s\n' "$*"; }

desired_perms() { # $1 = app-id, $2 = permission -> allow|deny
  if [[ "$2" == "allow" ]]; then printf 'true'; else printf 'false'; fi
}

apply_perm() { # $1 = app-id, $2 = permission, $3 = action
  local cmd
  if [[ "$3" == "allow" ]]; then
    cmd="pm grant '$1' '$2'"
  else
    cmd="pm revoke '$1' '$2'"
  fi
  if [[ "$MODE" == "check" ]]; then
    log "drift: $1 $2 should be $3"
    DRIFT=$((DRIFT + 1))
    return 0
  fi
  if [[ "$MODE" == "dry-run" ]]; then
    log "would: $cmd"
    return 0
  fi
  if run_root "$cmd" >/dev/null 2>&1; then
    log "applied: $1 $2=$3"
  else
    log "!! failed: $cmd" >&2
    FAILED=1
  fi
}

enforce_perm() { # $1 = app-id, $2 = permission, $3 = action (allow|deny)
  local live
  live="$(live_grant "$1" "$2")"
  if [[ -z "$live" ]]; then
    log "skip: $1 $2 is not a runtime permission on this device"
    return 0
  fi
  if [[ "$live" == "$(desired_perms "$1" "$3")" ]]; then
    log "ok: $1 $2=$3"
    return 0
  fi
  apply_perm "$1" "$2" "$3"
}

enforce_listeners() { # $1 = app-id
  local has
  has="$(jq -r --arg a "$1" '((.notifications // {})[$a] // {}) | has("listeners")' "$CONFIG")"
  if [[ "$has" != "true" ]]; then
    # No listeners declared for this app: leave its notification access
    # alone (an empty default must not switch anything off).
    return 0
  fi
  local desired live comp
  desired="$(notif_listeners "$1" | sort -u)"
  live="$(app_listeners "$1" | sort -u)"
  if [[ -z "$desired" && -z "$live" ]]; then
    return 0
  fi
  while IFS= read -r comp; do
    [[ -z "$comp" ]] && continue
    if grep -qxF "$comp" <<<"$live"; then
      log "ok: listener $comp enabled"
      continue
    fi
    if [[ "$MODE" == "check" ]]; then
      log "drift: listener $comp should be enabled"
      DRIFT=$((DRIFT + 1))
    elif [[ "$MODE" == "dry-run" ]]; then
      log "would: cmd notification allow_listener '$comp'"
    elif run_root "cmd notification allow_listener '$comp'" >/dev/null 2>&1; then
      log "applied: listener $comp enabled"
    else
      log "!! failed: enable listener $comp" >&2
      FAILED=1
    fi
  done <<<"$desired"
  # An app component that is enabled on the device but not in the config is
  # turned off: the config is the intent for that app's own listeners.
  while IFS= read -r comp; do
    [[ -z "$comp" ]] && continue
    if grep -qxF "$comp" <<<"$desired"; then
      continue
    fi
    if [[ "$MODE" == "check" ]]; then
      log "drift: listener $comp should be disabled"
      DRIFT=$((DRIFT + 1))
    elif [[ "$MODE" == "dry-run" ]]; then
      log "would: cmd notification disallow_listener '$comp'"
    elif run_root "cmd notification disallow_listener '$comp'" >/dev/null 2>&1; then
      log "applied: listener $comp disabled"
    else
      log "!! failed: disable listener $comp" >&2
      FAILED=1
    fi
  done <<<"$live"
}

enforce_flag() { # $1 = app-id, $2 = field, $3 = value, $4 = command
  if [[ "$MODE" == "check" ]]; then
    log "unverifiable: $1 $2=$3 (no readable state; applied on switch)"
    return 0
  fi
  if [[ "$MODE" == "dry-run" ]]; then
    log "would: $4"
    return 0
  fi
  if run_root "$4" >/dev/null 2>&1; then
    log "applied: $1 $2=$3"
  else
    log "!! failed: $4" >&2
    FAILED=1
  fi
}

apply_cmd() { # $1 = app-id, $2 = what changed, $3 = desired, $4 = command
  if [[ "$MODE" == "check" ]]; then
    log "drift: $1 $2 should be $3"
    DRIFT=$((DRIFT + 1))
    return 0
  fi
  if [[ "$MODE" == "dry-run" ]]; then
    log "would: $4"
    return 0
  fi
  if run_root "$4" >/dev/null 2>&1; then
    log "applied: $1 $2=$3"
  else
    log "!! failed: $4" >&2
    FAILED=1
  fi
}

enforce_appop() { # $1 = app-id, $2 = OP, $3 = allow|deny|ignore|foreground|default
  local live dflt
  live="$(live_appop "$1" "$2")"
  dflt="$(appop_default "$1" "$2")"
  if [[ -z "$live" && -z "$dflt" ]]; then
    log "skip: $1 app op $2 is unknown on this device"
    return 0
  fi
  if [[ "$3" == "default" ]]; then
    if [[ -z "$live" || "$live" == "default" ]]; then
      log "ok: $1 appop $2=default"
      return 0
    fi
  elif [[ "$live" == "$3" ]] || { [[ -z "$live" ]] && [[ "$dflt" == "$3" ]]; }; then
    log "ok: $1 appop $2=$3"
    return 0
  fi
  apply_cmd "$1" "appop $2" "$3" "appops set '$1' '$2' '$3'"
}

enforce_link_open() { # $1 = app-id, $2 = true|false
  local live
  live="$(live_link_allowed "$1")"
  if [[ -z "$live" ]]; then
    log "skip: $1 declares no app links"
    return 0
  fi
  if [[ "$live" == "$2" ]]; then
    log "ok: $1 link handling allowed=$2"
    return 0
  fi
  apply_cmd "$1" "link handling" "$2" \
    "pm set-app-links-allowed --user 0 --package '$1' '$2'"
}

enforce_link_domain() { # $1 = app-id, $2 = domain, $3 = allow|deny
  local declared state want flag
  declared="$(declared_link_domains "$1")"
  if [[ -z "$declared" ]]; then
    log "skip: $1 declares no app links"
    return 0
  fi
  state="$(live_link_state "$1" | awk -v d="$2" '$1 == d { print $2; exit }')"
  if [[ -z "$state" ]]; then
    log "!! $1 does not declare the domain $2 (declares: $(printf '%s' "$declared" | tr '\n' ' '))" >&2
    FAILED=1
    return 0
  fi
  if [[ "$3" == "allow" ]]; then want=enabled flag=true; else want=disabled flag=false; fi
  if [[ "$state" == "$want" ]]; then
    log "ok: $1 link $2=$3"
    return 0
  fi
  apply_cmd "$1" "link $2" "$3" \
    "pm set-app-links-user-selection --user 0 --package '$1' '$flag' '$2'"
}

enforce_links() { # $1 = app-id
  local open domain action
  open="$(link_open "$1")"
  case "$open" in
    null) ;;
    true | false) enforce_link_open "$1" "$open" ;;
    *)
      log "!! unknown links.open value for $1: $open" >&2
      FAILED=1
      ;;
  esac
  while read -r domain action; do
    [[ -z "$domain" ]] && continue
    case "$action" in
      allow | deny) enforce_link_domain "$1" "$domain" "$action" ;;
      *)
        log "!! unknown link action for $1 $domain: $action" >&2
        FAILED=1
        ;;
    esac
  done < <(link_entries "$1")
}

enforce_app() { # $1 = app-id
  local perm action enabled dnd bubbles op mode
  while read -r perm action; do
    [[ -z "$perm" ]] && continue
    enforce_perm "$1" "$perm" "$action"
  done < <(cfg_perms "$1")

  enabled="$(notif_field "$1" enabled)"
  if [[ "$enabled" != "null" ]]; then
    if [[ "$enabled" == "true" ]]; then
      enforce_perm "$1" android.permission.POST_NOTIFICATIONS allow
    else
      enforce_perm "$1" android.permission.POST_NOTIFICATIONS deny
    fi
  fi
  enforce_listeners "$1"

  dnd="$(notif_field "$1" dnd)"
  if [[ "$dnd" == "true" ]]; then
    enforce_flag "$1" dnd "$dnd" "cmd notification allow_dnd '$1'"
  elif [[ "$dnd" == "false" ]]; then
    enforce_flag "$1" dnd "$dnd" "cmd notification disallow_dnd '$1'"
  fi

  bubbles="$(notif_field "$1" bubbles)"
  case "$bubbles" in
    null) ;;
    none) enforce_flag "$1" bubbles "$bubbles" "cmd notification set_bubbles '$1' 0" ;;
    all) enforce_flag "$1" bubbles "$bubbles" "cmd notification set_bubbles '$1' 1" ;;
    selected) enforce_flag "$1" bubbles "$bubbles" "cmd notification set_bubbles '$1' 2" ;;
    *)
      log "!! unknown bubbles value for $1: $bubbles" >&2
      FAILED=1
      ;;
  esac

  while read -r op mode; do
    [[ -z "$op" ]] && continue
    case "$mode" in
      allow | deny | ignore | foreground | default) enforce_appop "$1" "$op" "$mode" ;;
      *)
        log "!! unknown appop mode for $1 $op: $mode" >&2
        FAILED=1
        ;;
    esac
  done < <(cfg_appops "$1")

  enforce_links "$1"
}

# --- dump: current state as Nix --------------------------------------------
# Mirrors the *user's* choices (USER_SET) so it can be dropped into the dotfiles
# and applied without changing anything.
dump_nix() {
  local app first perm granted enabled comp
  local open domain state body line op mode

  log "{"
  log "  # Generated by \`android-enforce --dump\` — the declared apps' current"
  log "  # runtime permissions (the ones you set), notification access and the link"
  log "  # domains you chose to open in the app."
  log "  permissions = {"
  while IFS= read -r app; do
    [[ -z "$app" ]] && continue
    first=1
    while read -r perm granted; do
      [[ -z "$perm" ]] && continue
      [[ "$perm" == "android.permission.POST_NOTIFICATIONS" ]] && continue
      if [[ "$first" == 1 ]]; then
        log "    \"$app\" = {"
        first=0
      fi
      if [[ "$granted" == "true" ]]; then
        log "      \"$perm\" = \"allow\";"
      else
        log "      \"$perm\" = \"deny\";"
      fi
    done < <(user_set_perms "$app")
    if [[ "$first" == 0 ]]; then
      log "    };"
    fi
  done < <(cfg_apps)

  log "  };"
  log "  notifications = {"
  while IFS= read -r app; do
    [[ -z "$app" ]] && continue
    first=1
    enabled="$(live_runtime_perms "$app" | awk '$1 == "android.permission.POST_NOTIFICATIONS" && $3 ~ /USER_SET/ { print $2; exit }')"
    if [[ -n "$enabled" ]]; then
      if [[ "$first" == 1 ]]; then
        log "    \"$app\" = {"
        first=0
      fi
      if [[ "$enabled" == "true" ]]; then
        log "      enabled = true;"
      else
        log "      enabled = false;"
      fi
    fi
    while IFS= read -r comp; do
      [[ -z "$comp" ]] && continue
      if [[ "$first" == 1 ]]; then
        log "    \"$app\" = {"
        first=0
      fi
      log "      listeners = [ \"$comp\" ];"
    done < <(app_listeners "$app")
    if [[ "$first" == 0 ]]; then
      log "    };"
    fi
  done < <(cfg_apps)
  log "  };"

  # Open-by-default links: only the user's choices. A domain listed under
  # "Disabled" and link handling allowed is the device default, so it is not
  # dumped; an *enabled* domain (or a disabled master switch) is.
  first=1
  while IFS= read -r app; do
    [[ -z "$app" ]] && continue
    body=""
    if [[ "$(live_link_allowed "$app")" == "false" ]]; then
      body+="      open = false;"$'\n'
    fi
    while read -r domain state; do
      [[ -z "$domain" || "$state" != "enabled" ]] && continue
      body+="      domains.\"$domain\" = \"allow\";"$'\n'
    done < <(live_link_state "$app")
    [[ -z "$body" ]] && continue
    if [[ "$first" == 1 ]]; then
      log "  links = {"
      first=0
    fi
    log "    \"$app\" = {"
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      log "$line"
    done <<<"$body"
    log "    };"
  done < <(cfg_apps)
  if [[ "$first" == 0 ]]; then
    log "  };"
  fi

  if [[ "$DUMP_APP_OPS" == 1 ]]; then
    log "  # Opt-in via --dump-appops: app ops are noisy (appops reports targetSdk-"
    log "  # derived modes too), so they are left out of a plain --dump."
    log "  appops = {"
    while IFS= read -r app; do
      [[ -z "$app" ]] && continue
      first=1
      while read -r op mode; do
        [[ -z "$op" ]] && continue
        if [[ "$first" == 1 ]]; then
          log "    \"$app\" = {"
          first=0
        fi
        log "      $op = \"$mode\";"
      done < <(live_appop_modes "$app")
      if [[ "$first" == 0 ]]; then
        log "    };"
      fi
    done < <(cfg_apps)
    log "  };"
  fi

  log "}"
}

# --- main ------------------------------------------------------------------
case "$MODE" in
  dump)
    dump_nix
    ;;
  *)
    if [[ -n "$ONLY" ]]; then
      enforce_app "$ONLY"
    else
      while IFS= read -r app; do
        [[ -z "$app" ]] && continue
        enforce_app "$app"
      done < <(managed_apps)
    fi
    if [[ "$MODE" == "check" ]]; then
      if [[ "$FAILED" != 0 ]]; then
        log ""
        log "!! config errors above (nothing drifted, but not everything could be checked)" >&2
        exit 1
      fi
      if [[ "$DRIFT" -gt 0 ]]; then
        log ""
        log "!! $DRIFT difference(s) between the config and the device"
        exit 1
      fi
      log ""
      log "OK: declared permissions, notifications, app ops and links match the device"
    fi
    if [[ "$FAILED" != 0 ]]; then
      exit 1
    fi
    ;;
esac
