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
#   scripts/enforce.sh --config <config.json> --dump --dump-all       # every grant
#   scripts/enforce.sh --config <config.json> --recommended <index.json>  # + curated
#   scripts/enforce.sh --config <config.json> --dump --dump-appops   # + app ops
#   scripts/enforce.sh --config <config.json> --print-effective  # canonical config
#   scripts/enforce.sh --config <config.json> --only com.app
#   scripts/enforce.sh -s <serial> --config <config.json>  # adb instead of on-device
#
# Config shape (the home-manager module renders this from aliyss.androidPkgs):
# one block per app, keyed by app-id — the key *is* the declaration, and the
# block is everything declared about that app:
#
#   { "mode": "overrides",                    # overrides | managed | recommended
#     "apps": {
#       "com.app": {
#         "mode": "managed",                  # optional per-app override
#         "permissions": {
#           "android.permission.CAMERA": "allow"                 # or "deny"
#         },
#         "notifications": {
#           "enabled": false,                 # POST_NOTIFICATIONS granted/revoked
#           "listeners": ["com.app/.Listener"],  # notification-access components
#           "dnd": true,                      # exempt from Do Not Disturb
#           "bubbles": "none"                 # none | all | selected
#         },
#         "appops": {
#           "RUN_ANY_IN_BACKGROUND": "allow"
#         },                                  # allow | deny | ignore | foreground | default
#         "links": {
#           "open": false,                    # open-by-default ("link handling allowed")
#           "domains": { "wa.me": "allow" }   # allow | deny, per verified domain
#         }
#       },
#       "com.other": {}                       # declared (installed), no state
#     }
#   }
#
# An app-id that is not a key is not declared: it is uninstalled, and nothing
# about it is declared anywhere else, so an app never has to be removed from
# several maps. The older flat layout (an `apps` array plus one map per kind —
# `permissions`, `notifications`, `appops`, `links`, `appModes`) is still
# accepted and folded into this form, so a config written before the change
# keeps working unchanged.
#
# Semantics: the default mode (`overrides`) treats the config as additions — an
# app with no entry is untouched and an unlisted permission/op/domain is never
# touched, so dumping the current state (`--dump`) and feeding it back is a
# no-op. `managed` is the other posture: for each app the config is the whole
# intent, so anything granted but not listed is taken away. It only removes
# grants — an unset op stays at the platform default — and it leaves
# POST_NOTIFICATIONS to `notifications.enabled`, so a managed switch does not
# silence every app that has no notification entry. Of the app ops only the ones
# Settings exposes as toggles (background activity, install unknown apps, draw
# over other apps, ...) take part; the rest are platform-internal behaviour
# flags where `deny` would break the app rather than protect you.
#
# Modes: `overrides` (default), `managed` and `recommended`; see the semantics
# note above. `recommended` is `managed` with the app's own curated block (a
# `recommended.json` sidecar shipped in aliyss-android-pkgs, passed here as
# `--recommended <index.json>`) as the baseline: the curated block first, this
# config on top, and whatever is left unlisted taken away. The index never
# declares an app — it can only fill in state for an app the config declares —
# so a curated app that is not installed stays uninstalled. An app with no
# sidecar still works: it falls back to this config plus the managed default,
# and `--check` reports it as uncurated.
#
# Layers implemented (all per-app, under `apps.<app-id>`):
#   * runtime permissions  `permissions."<perm>"`      pm grant / pm revoke
#   * notifications        `notifications.{enabled,listeners,dnd,bubbles}`
#   * app ops              `appops.<OP>`               appops set
#   * open-by-default      `links.open`                pm set-app-links-allowed
#   * link domains         `links.domains.<domain>`    pm set-app-links-user-selection
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
DUMP_ALL=0
RECOMMENDED=""

# The app ops Settings exposes as toggles. `managed` revokes these when they are
# not listed. ACCESS_RESTRICTED_SETTINGS is deliberately absent: it is not a
# privacy toggle but the switch that lets a sideloaded app use accessibility
# services, notification access and install-unknown-apps at all.
# Every other op is platform-internal (wake locks, audio focus, clipboard,
# volume) where `deny` breaks the app rather than protecting you.
MANAGED_APP_OPS="RUN_ANY_IN_BACKGROUND REQUEST_INSTALL_PACKAGES SYSTEM_ALERT_WINDOW WRITE_SETTINGS SCHEDULE_EXACT_ALARM GET_USAGE_STATS MANAGE_EXTERNAL_STORAGE"

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
    --dump-all)
      DUMP_ALL=1
      shift
      ;;
    --print-effective)
      MODE=effective
      shift
      ;;
    --recommended)
      RECOMMENDED="$2"
      shift 2
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

# --- config ----------------------------------------------------------------
# Fold every accepted shape into one canonical form, and (when an index is
# given) the curated per-app blocks under this config. Everything below reads
# the canonical form — `apps.<app-id>`, with the effective mode written per app
# — so the shape is understood in one place instead of in every accessor.
#
#   * per-app (canonical: what the module renders and --dump writes)
#   * flat (the older `apps` array + one map per kind; lifted into the bodies)
#
# `recommended` apps take their curated block as a baseline under this config.
# Only apps whose effective mode is `recommended` are touched by the index, and
# the index never declares an app: it can only fill in state for an app the
# config declares.
normalize_config() { # $1 = config, $2 = recommended index ("" for none)
  local index="${2:-}"
  jq -n --slurpfile cfg "$1" --slurpfile rec "${index:-/dev/null}" '
    ($cfg[0]) as $c
    | ($rec[0] // {}) as $r
    | ($c.apps | type) as $ct
    # The declared apps as one attrset of app-id -> body. The flat layout
    # carried the ids in an array and the state in one map per kind; lift those
    # maps into the bodies so there is a single place per app afterwards.
    | (if $c.apps == null then {}
       elif $ct == "array" then ($c.apps | map({ (.): {} }) | add // {})
       else $c.apps end) as $declared
    | (if $ct != "array" then $declared
       else
         reduce ($c | ["permissions", "notifications", "appops", "links"][]) as $l
           ($declared;
             reduce (($c[$l] // {}) | to_entries[]) as $e (.;
               .[$e.key] = ((.[$e.key] // {}) + { ($l): $e.value })))
       end) as $bodies
    # Effective mode: the app own mode > the old appModes map > global.
    | def mode_of($a): ($bodies[$a].mode // $c.appModes[$a] // $c.mode // "overrides");
      # A null from the module means "not declared here", never "clear this":
      # the field defaults in the option are null, so they must not overwrite a
      # curated baseline.
      def clean: with_entries(select(.value != null));
      def curated($a): (mode_of($a) == "recommended");
      def curated_block($a): (if curated($a) then ($r[$a] // {}) else {} end);
      def body($a):
        ($bodies[$a]) as $b
        | (curated_block($a)) as $cur
        | {
            mode: mode_of($a),
            permissions: (($cur.permissions // {}) + ($b.permissions // {})),
            appops: (($cur.appops // {}) + ($b.appops // {})),
            notifications:
              ((($cur.notifications // {}) + (($b.notifications // {}) | clean)) | clean),
            links: {
              open: (if $b.links.open != null then $b.links.open else $cur.links.open end),
              domains: (($cur.links.domains // {}) + ($b.links.domains // {}))
            }
          };
      {
        mode: ($c.mode // "overrides"),
        apps: (reduce ($bodies | keys[]) as $a ({}; . + { ($a): body($a) }))
      }
  '
}

# The canonical config every reader below uses, written once to a temp file.
if [[ -n "$RECOMMENDED" && ! -r "$RECOMMENDED" ]]; then
  echo "error: cannot read the recommended index: $RECOMMENDED" >&2
  exit 2
fi
EFFECTIVE="$(mktemp "${TMPDIR:-/tmp}/android-enforce-effective.XXXXXX")"
# Live state is fetched once into $SNAP (see "live state" below): every read the
# walk makes is a file lookup, not a root round trip. The captured output never
# leaves this process, so it lives in TMPDIR.
SNAP="$(mktemp -d "${TMPDIR:-/tmp}/android-enforce-live.XXXXXX")"
# The scripts handed to root are different: root runs in the *global* mount
# namespace (that is what the ksud shim's `-g` does, and the activation runs
# inside a chroot), so a TMPDIR path may not exist there. $HOME is a real path in
# both namespaces — the su shim already lives under it for the same reason.
ROOT_TMP="${HOME:-/data/data/com.termux/files/home}/.local/state/aliyss-android-pkgs.d"
mkdir -p "$ROOT_TMP" 2>/dev/null || ROOT_TMP="${TMPDIR:-/tmp}"
READ_SCRIPT="$ROOT_TMP/enforce-read.$$.sh"
APPLY_SCRIPT="$ROOT_TMP/enforce-apply.$$.sh"
trap 'rm -rf "$EFFECTIVE" "$SNAP" "$READ_SCRIPT" "$APPLY_SCRIPT"' EXIT
if ! normalize_config "$CONFIG" "$RECOMMENDED" >"$EFFECTIVE"; then
  echo "error: could not read the config: $CONFIG" >&2
  exit 2
fi
CONFIG="$EFFECTIVE"

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

# The Android system binaries the generated root scripts must find (dumpsys,
# appops, pm, settings). Overridable so the walk can be exercised against fakes.
SYSTEM_PATH="${AS_SYSTEM_PATH:-/system/bin:/system/xbin:/vendor/bin}"

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
# --print-effective only reads the config, so it must work without root.
if [[ "$MODE" != "effective" && ${#ADB[@]} -eq 0 ]]; then
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

# A root round trip is a process spawn on the phone (~35ms idle, ~150ms with a
# `dumpsys` behind it), so a command per setting does not scale: the walk used
# to issue ~2000 of them for a 113-app config. Everything root does is therefore
# written into a script and handed over ONCE — this is that hand-over.
#
# On-device the script sits under $HOME where root can read it. Over adb the file
# is on the *host*, so the script is piped through stdin instead (`sh -s`).
run_root_script() { # $1 = local script path
  if [[ ${#ADB[@]} -gt 0 ]]; then
    "${ADB[@]}" shell "su -c 'sh -s'" <"$1"
  else
    "$SU" -c "sh '$1'"
  fi
}

# Single-quote a value for a generated script. App ids, permissions, ops and
# domains are interpolated into commands that root's sh will parse, so a quote
# in the config must not be able to escape its argument.
sq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

# --- live state: one root round trip ---------------------------------------
# Every read the walk makes is answered from a snapshot fetched up front. The
# walk asks the same questions over and over — the grant for each declared
# permission, each op's mode *and* its default, the link state per domain — and
# each answer used to be its own `su` spawn (a 113-app config measured 2006 of
# them, 2m04s). One script now fetches everything, and the answers are files.

# App ids and op names are interpolated into that script, so they are validated
# first. Both are identifiers: app ids are reverse-DNS package names, ops are
# upper-snake-case.
safe_key() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }

# The ops this app's walk asks about per-op. `appops get <pkg>` lists only the
# ops that are explicitly set; an op's *default* mode (which depends on the
# app's targetSdk) is only answered by the per-op query — so exactly those are
# prefetched: only the ops the config declares (the managed set is read from the
# full listing instead).
app_ops_of_interest() { # $1 = app-id -> OP names, one per line
  # Only the ops the config names: a per-op query is needed to learn an op's
  # *default*, and only a declared op is ever compared against its default. The
  # managed posture does not need it — it only revokes ops that are explicitly
  # allowed, which the full `appops get <pkg>` listing already carries (see
  # live_appop_curated). Fetching the managed set per op cost ~7 root reads per
  # app and was most of the walk's remaining time.
  cfg_appops "$1" | awk '{ print $1 }'
}

# Fetch everything in one root script: the global notification-listener setting,
# then per app the package dump, the app-link state, the app-op listing and the
# per-op queries.
prefetch_live() { # $1 = newline-separated app ids
  local app op script="$READ_SCRIPT"
  local -a apps=()
  while IFS= read -r app; do
    [[ -z "$app" ]] && continue
    if ! safe_key "$app"; then
      log "!! unsafe app id, not read: $app" >&2
      FAILED=1
      continue
    fi
    apps+=("$app")
  done <<<"$1"

  {
    printf 'PATH=%s\nexport PATH\n' "$SYSTEM_PATH"
    # The marker has to be ECHOED — as a bare word sh would try to run it, and
    # the answer it labels would arrive unlabelled.
    printf 'echo "@@AS@@ listeners"\n'
    printf 'settings get secure enabled_notification_listeners 2>/dev/null || true\n'
    for app in "${apps[@]}"; do
      printf 'echo "@@AS@@ pkg %s"\ndumpsys package %s 2>/dev/null || true\n' "$app" "$app"
      printf 'echo "@@AS@@ links %s"\npm get-app-links --user 0 %s 2>/dev/null || true\n' "$app" "$app"
      printf 'echo "@@AS@@ appops %s"\nappops get %s 2>/dev/null || true\n' "$app" "$app"
      while IFS= read -r op; do
        [[ -z "$op" ]] && continue
        safe_key "$op" || continue
        printf 'echo "@@AS@@ appop %s %s"\nappops get %s %s 2>/dev/null || true\n' \
          "$app" "$op" "$app" "$op"
      done < <(app_ops_of_interest "$app")
    done
    printf 'exit 0\n'
  } >"$script"

  if ! run_root_script "$script" >"$SNAP/raw" 2>/dev/null; then
    log "!! could not read the device state (root denied?)" >&2
    return 1
  fi
  split_snapshot "$SNAP/raw"
  rm -f "$script"
}

# Split the marked output into one file per answer: <kind>.<key>. An app-op
# answer is keyed by app and op, so live_appop and appop_default share one call.
split_snapshot() { # $1 = raw output
  local dir="$SNAP/live"
  mkdir -p "$dir"
  awk -v dir="$dir" '
    /^@@AS@@ / {
      kind = $2; key = $3
      if (kind == "appop") key = $3 "." $4
      if (key == "") key = "-"
      file = dir "/" kind "." key
      next
    }
    file != "" { print > file }
  ' "$1"
}

snap() { # $1 = kind, $2 = key -> the captured text (empty when never fetched)
  local f="$SNAP/live/$1.${2:--}"
  [[ -f "$f" ]] && cat "$f"
  return 0
}

# `dumpsys package` lists every runtime permission with its grant state; the
# trailing flags say whether the *user* set it (USER_SET), which is what --dump
# mirrors: the choices you made, not the OS defaults.
live_runtime_perms() { # $1 = app-id -> "perm granted flags"
  snap pkg "$1" \
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
  snap listeners | tr -d '\r'
}

app_listeners() { # $1 = app-id -> its enabled listener components
  live_listeners | tr ':' '\n' | grep -F "$1/" || true
}

# `appops get <app> <OP>` answers with "<OP>: <mode>" when the op is set and
# "Default mode: <mode>" when it is not, so both are read here: an unset op is
# equivalent to its default, and --check compares against that.
live_appop() { # $1 = app-id, $2 = OP -> mode or (empty)
  snap appop "$1.$2" \
    | sed -n "s/^\(Uid mode: \)\?$2: \(allow\|deny\|ignore\|foreground\|default\).*/\2/p" \
    | head -1 || true
}

appop_default() { # $1 = app-id, $2 = OP -> the op's default mode or (empty)
  snap appop "$1.$2" \
    | sed -n 's/^Default mode: \(allow\|deny\|ignore\|foreground\|default\)$/\1/p' \
    | head -1 || true
}

# Every statically configured op (no runtime telemetry) minus the ops that only
# mirror a runtime permission — those are the `permissions` block's job, and
# appops reports them for every app based on its targetSdk.
live_appop_modes() { # $1 = app-id -> "OP mode"
  local perms
  perms="$(live_runtime_perms "$1" | awk '{ print $1 }' | sed 's/.*\.//')"
  snap appops "$1" | awk '
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

# The managed app ops that are explicitly set for an app, telemetry or not.
# `live_appop_modes` filters runtime noise, which is right for browsing but
# wrong here: an op like `allow; time=...` is still a grant.
live_appop_curated() { # $1 = app-id -> "OP mode"
  # First entry per op wins: the listing repeats an op when its mode was changed
  # at runtime (`... allow`, then `... deny; time=...`), and the untimed line is
  # the configured mode. `seen` keeps the configured one.
  snap appops "$1" | awk -v list="$MANAGED_APP_OPS" '
    BEGIN { n = split(list, ops, " "); for (i = 1; i <= n; i++) want[ops[i]] = 1 }
    {
      l = $0; sub(/\r$/, "", l); sub(/^Uid mode: /, "", l)
      if (l !~ /^[A-Z0-9_]+: /) next
      op = l; sub(/:.*/, "", op)
      if (!(op in want)) next
      if (op in seen) next
      seen[op] = 1
      mode = l; sub(/^[^:]*: /, "", mode); sub(/;.*/, "", mode)
      print op, mode
    }'
}

live_link_allowed() { # $1 = app-id -> true|false|(empty)
  snap links "$1" \
    | sed -n 's/^ *Verification link handling allowed: \(true\|false\)$/\1/p' \
    | head -1 || true
}

live_link_state() { # $1 = app-id -> "domain enabled|disabled"
  snap links "$1" | awk -v app="$1" '
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
  snap links "$1" \
    | sed -n '/Domain verification state:/,/^ *User /p' \
    | sed -n 's/^ *\([A-Za-z0-9._-]*\): .*/\1/p' || true
}

# --- config access ---------------------------------------------------------
# One app-id is one declaration: the key says the app is declared, and its body
# holds everything declared about it.
#
# The config is read ONCE into bash arrays. Each accessor below used to be its
# own `jq`, which is ~31ms on a phone and the walk asks about a dozen things per
# app: for a 113-app config that was ~42s, more than all the root calls it had
# just replaced. Reading the file is one `jq`; a lookup is an array read.
declare -A CFG_MODE=() CFG_PERM=() CFG_APPOP=() CFG_NOTIF=() CFG_DOMAIN=() CFG_LINK_OPEN=()
declare -A CFG_PERM_LIST=() CFG_APPOP_LIST=() CFG_DOMAIN_LIST=() CFG_LISTENER_LIST=()
declare -A CFG_HAS_LISTENERS=() CFG_RECURATED=()
CFG_APPS=()
CFG_MODE_GLOBAL=overrides

# Flatten the canonical config (and, when one was given, the curated index) into
# tab-separated records: app, kind, key, value. `@tsv` keeps a value with a tab
# or a newline readable as one field.
load_config() { # $1 = config, $2 = recommended index ("" for none)
  local app kind key value
  # An empty field must never reach `read`: IFS=$'\t' is a whitespace IFS, so a
  # run of two tabs collapses into one and every field after the gap shifts left
  # (the global/app `mode` records, whose key is empty, were dropped this way).
  # `rec` writes "-" for an empty field and it is decoded back here.
  while IFS=$'\t' read -r app kind key value; do
    [[ "$app" == "-" ]] && app=""
    [[ "$key" == "-" ]] && key=""
    [[ "$value" == "-" ]] && value=""
    case "$kind" in
      global) CFG_MODE_GLOBAL="$value" ;;
      app)
        CFG_MODE[$app]="$value"
        CFG_APPS+=("$app")
        ;;
      perm)
        CFG_PERM["$app|$key"]="$value"
        CFG_PERM_LIST[$app]+="$key"$'\n'
        ;;
      appop)
        CFG_APPOP["$app|$key"]="$value"
        CFG_APPOP_LIST[$app]+="$key"$'\n'
        ;;
      notif) CFG_NOTIF["$app|$key"]="$value" ;;
      listener)
        CFG_LISTENER_LIST[$app]+="$key"$'\n'
        CFG_HAS_LISTENERS[$app]=1
        ;;
      haslisteners) CFG_HAS_LISTENERS[$app]=1 ;;
      domain)
        CFG_DOMAIN["$app|$key"]="$value"
        CFG_DOMAIN_LIST[$app]+="$key"$'\n'
        ;;
      linkopen) CFG_LINK_OPEN[$app]="$value" ;;
      curated) CFG_RECURATED[$app]=1 ;;
    esac
  done < <(jq -r --slurpfile idx "${2:-/dev/null}" '
    def rec($a; $k; $key; $v): ([$a, $k, $key, ($v | tostring)]
      | map(if . == "" then "-" else . end) | @tsv);
    (.mode // "overrides") as $g
    | ((($idx[0] // {}) | keys[]) as $c | rec($c; "curated"; ""; "1")),
      rec(""; "global"; ""; $g),
      (.apps | to_entries[] | .key as $a | .value as $b
       | rec($a; "app"; ""; ($b.mode // $g)),
         (($b.permissions // {}) | to_entries[] | rec($a; "perm"; .key; .value)),
         (($b.appops // {}) | to_entries[]
          | select(.key | test("^[A-Z0-9_]+$"))
          | rec($a; "appop"; .key; .value)),
         (($b.notifications // {}) | to_entries[]
          | select((.value | type) != "array")
          | rec($a; "notif"; .key; .value)),
         ((($b.notifications // {}).listeners // []) | .[] | rec($a; "listener"; .; "")),
         (if (($b.notifications // {}) | has("listeners"))
          then rec($a; "haslisteners"; ""; "1") else empty end),
         (if (($b.links // {}).open // null) != null
          then rec($a; "linkopen"; ""; ($b.links // {}).open) else empty end),
         (($b.links.domains // {}) | to_entries[] | rec($a; "domain"; .key; .value))
      )' "$CONFIG")
}

cfg_apps() { # the declared app-ids
  printf '%s\n' "${CFG_APPS[@]:-}"
}

managed_apps() { # the apps to walk
  # Globally managed: every declared app has to be visited, since the point is
  # to take away what the config does not list.
  if managed_like "$CFG_MODE_GLOBAL"; then
    cfg_apps
    return 0
  fi
  # Otherwise only the apps that say something: state to apply, or a mode of
  # their own (which is what makes a per-app managed/deny-all entry work).
  local a
  for a in "${CFG_APPS[@]:-}"; do
    [[ -z "$a" ]] && continue
    if [[ "$(app_mode "$a")" != "$CFG_MODE_GLOBAL" ]] \
      || [[ -n "${CFG_PERM_LIST[$a]:-}" || -n "${CFG_APPOP_LIST[$a]:-}" ]] \
      || [[ -n "${CFG_DOMAIN_LIST[$a]:-}" || -n "${CFG_LINK_OPEN[$a]:-}" ]] \
      || [[ -n "${CFG_HAS_LISTENERS[$a]:-}" ]] \
      || [[ -n "${CFG_NOTIF["$a|enabled"]:-}" || -n "${CFG_NOTIF["$a|dnd"]:-}" \
        || -n "${CFG_NOTIF["$a|bubbles"]:-}" ]]; then
      printf '%s\n' "$a"
    fi
  done
}

cfg_perms() { # $1 = app-id -> "perm action"
  local p
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    printf '%s %s\n' "$p" "${CFG_PERM["$1|$p"]:-}"
  done <<<"${CFG_PERM_LIST[$1]:-}"
}

notif_field() { # $1 = app-id, $2 = field -> value or "null"
  printf '%s' "${CFG_NOTIF["$1|$2"]:-null}"
}

notif_listeners() { # $1 = app-id -> desired components
  printf '%s\n' "${CFG_LISTENER_LIST[$1]:-}"
}

notif_has_listeners() { # $1 = app-id -> did the config declare `listeners` at all?
  [[ -n "${CFG_HAS_LISTENERS[$1]:-}" ]]
}

cfg_appops() { # $1 = app-id -> "OP mode" (op names are validated: they reach sed)
  local op
  while IFS= read -r op; do
    [[ -z "$op" ]] && continue
    printf '%s %s\n' "$op" "${CFG_APPOP["$1|$op"]:-}"
  done <<<"${CFG_APPOP_LIST[$1]:-}"
}

link_open() { # $1 = app-id -> true|false|null
  printf '%s' "${CFG_LINK_OPEN[$1]:-null}"
}

link_entries() { # $1 = app-id -> "domain allow|deny"
  local d
  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    printf '%s %s\n' "$d" "${CFG_DOMAIN["$1|$d"]:-}"
  done <<<"${CFG_DOMAIN_LIST[$1]:-}"
}

curated_app() { # $1 = app-id -> does the recommended index carry it?
  [[ -n "${CFG_RECURATED[$1]:-}" ]]
}

managed_like() { # $1 = mode -> is it the deny-all-not-listed posture?
  [[ "$1" == "managed" || "$1" == "recommended" ]]
}

cfg_mode() { # global default: overrides | managed | recommended
  printf '%s' "$CFG_MODE_GLOBAL"
}

app_mode() { # $1 = app-id -> overrides | managed | recommended
  printf '%s' "${CFG_MODE[$1]:-$CFG_MODE_GLOBAL}"
}

# --- actions ---------------------------------------------------------------
log() { printf '%s\n' "$*"; }

# Changes are collected and applied in ONE root script at the end, for the same
# reason the reads are prefetched: a root spawn per setting does not scale. Each
# command reports its own exit status, so a failure is still attributable and
# still fails the switch.
QUEUE_DESC=()
QUEUE_CMD=()

queue_cmd() { # $1 = description, $2 = root command
  QUEUE_DESC+=("$1")
  QUEUE_CMD+=("$2")
  log "apply: $1"
}

flush_queue() {
  [[ ${#QUEUE_CMD[@]} -eq 0 ]] && return 0
  local script="$APPLY_SCRIPT" i rc out
  {
    printf 'PATH=%s\nexport PATH\n' "$SYSTEM_PATH"
    for i in "${!QUEUE_CMD[@]}"; do
      printf '%s\n' "${QUEUE_CMD[$i]}"
      # Marker per command: the batch runs to completion either way, so one
      # failure cannot hide the commands after it.
      printf 'printf "@@AS@@ %s %%s\\n" "$?"\n' "$i"
    done
    printf 'exit 0\n'
  } >"$script"

  out="$(run_root_script "$script" 2>/dev/null)" || true

  for i in "${!QUEUE_CMD[@]}"; do
    rc="$(awk -v i="$i" '$1 == "@@AS@@" && $2 == i { print $3; exit }' <<<"$out")"
    if [[ "$rc" == 0 ]]; then
      log "applied: ${QUEUE_DESC[$i]}"
    else
      log "!! failed: ${QUEUE_DESC[$i]} (exit ${rc:-?}): ${QUEUE_CMD[$i]}" >&2
      FAILED=1
    fi
  done
  log "changed ${#QUEUE_CMD[@]} setting(s)"
  rm -f "$script"
}

desired_perms() { # $1 = app-id, $2 = permission -> allow|deny
  if [[ "$2" == "allow" ]]; then printf 'true'; else printf 'false'; fi
}

apply_perm() { # $1 = app-id, $2 = permission, $3 = action
  local cmd
  if [[ "$3" == "allow" ]]; then
    cmd="pm grant $(sq "$1") $(sq "$2")"
  else
    cmd="pm revoke $(sq "$1") $(sq "$2")"
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
  queue_cmd "$1 $2=$3" "$cmd"
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
  if ! notif_has_listeners "$1"; then
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
      log "would: cmd notification allow_listener $(sq "$comp")"
    else
      queue_cmd "listener $comp enabled" "cmd notification allow_listener $(sq "$comp")"
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
      log "would: cmd notification disallow_listener $(sq "$comp")"
    else
      queue_cmd "listener $comp disabled" "cmd notification disallow_listener $(sq "$comp")"
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
  queue_cmd "$1 $2=$3" "$4"
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
  queue_cmd "$1 $2=$3" "$4"
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
  apply_cmd "$1" "appop $2" "$3" "appops set $(sq "$1") $(sq "$2") $(sq "$3")"
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
    "pm set-app-links-allowed --user 0 --package $(sq "$1") $(sq "$2")"
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
    "pm set-app-links-user-selection --user 0 --package $(sq "$1") $(sq "$flag") $(sq "$2")"
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

# --- managed mode: take away what the config does not list ----------------
# Only grants are removed: a permission that is not currently held and an op
# that is unset (i.e. at its platform default) are left alone.
enforce_managed_perms() { # $1 = app-id
  local allowed perm granted
  allowed="$(cfg_perms "$1" | awk '$2 == "allow" { print $1 }')"
  while read -r perm granted _rest; do
    [[ -z "$perm" || "$granted" != "true" ]] && continue
    # Notifications are `notifications.enabled`'s business: revoking
    # POST_NOTIFICATIONS for every app without a notification entry would
    # silently silence the phone.
    [[ "$perm" == "android.permission.POST_NOTIFICATIONS" ]] && continue
    grep -qxF "$perm" <<<"$allowed" && continue
    apply_cmd "$1" "$perm" "deny (managed)" "pm revoke $(sq "$1") $(sq "$perm")"
  done < <(live_runtime_perms "$1")
}

enforce_managed_appops() { # $1 = app-id
  local listed op live
  listed="$(cfg_appops "$1" | awk '{ print $1 }')"
  # The ops explicitly set for this app, read from the full listing the snapshot
  # already holds — one root read per app instead of one per managed op.
  while read -r op live; do
    [[ -z "$op" ]] && continue
    grep -qxF "$op" <<<"$listed" && continue
    # An unset op already means the platform default; only explicit grants are
    # ours to revoke.
    case "$live" in
      allow | foreground) ;;
      *) continue ;;
    esac
    apply_cmd "$1" "appop $op" "deny (managed)" "appops set $(sq "$1") $(sq "$op") deny"
  done < <(live_appop_curated "$1")
}

enforce_managed_links() { # $1 = app-id
  local listed domain state
  listed="$(link_entries "$1" | awk '{ print $1 }')"
  while read -r domain state; do
    [[ -z "$domain" || "$state" != "enabled" ]] && continue
    grep -qxF "$domain" <<<"$listed" && continue
    apply_cmd "$1" "link $domain" "deny (managed)" \
      "pm set-app-links-user-selection --user 0 --package $(sq "$1") false $(sq "$domain")"
  done < <(live_link_state "$1")
}

enforce_app() { # $1 = app-id
  local perm action enabled dnd bubbles op opmode appmode
  appmode="$(app_mode "$1")"
  case "$appmode" in
    overrides | managed | recommended) ;;
    *)
      log "!! unknown mode for $1: $appmode" >&2
      FAILED=1
      appmode=overrides
      ;;
  esac
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

  while read -r op opmode; do
    [[ -z "$op" ]] && continue
    case "$opmode" in
      allow | deny | ignore | foreground | default) enforce_appop "$1" "$op" "$opmode" ;;
      *)
        log "!! unknown appop mode for $1 $op: $opmode" >&2
        FAILED=1
        ;;
    esac
  done < <(cfg_appops "$1")

  enforce_links "$1"

  # Not curated in the packages and running under `recommended`: say so once per
  # app in --check, since the managed default is about to decide for it.
  if [[ "$appmode" == "recommended" && -n "$RECOMMENDED" && "$MODE" == "check" ]]; then
    if ! curated_app "$1"; then
      uncurated="$(live_runtime_perms "$1" | awk \
        '$2 == "true" && $1 != "android.permission.POST_NOTIFICATIONS"' | wc -l | tr -d ' ')"
      log "warn: $1 has no recommended block ($uncurated grant(s) default to deny)"
    fi
  fi

  # managed / recommended: whatever the config (and, for recommended, the app's
  # curated block) does not list is taken away, on top of the additions above.
  if managed_like "$appmode"; then
    enforce_managed_perms "$1"
    enforce_managed_appops "$1"
    enforce_managed_links "$1"
  fi
}

# --- dump: current state as Nix --------------------------------------------
# Mirrors the *user's* choices (USER_SET) so it can be dropped into the dotfiles
# and applied without changing anything. One block per app, matching the module's
# `apps` option, so the file is the whole declaration of the phone's apps rather
# than one slice of it:
#
#   apps = import ./android-app-state.nix;
dump_nix() {
  local app body perms perm granted enabled comp op mode open domain state line
  local listeners

  if [[ "$DUMP_ALL" == 1 ]]; then
    log "# Generated by \`android-enforce --dump --dump-all\` — the declared apps'"
    log "# full current state: every runtime permission they hold, notification"
    log "# access, the app ops that are explicitly granted and the link domains"
    log "# that open in the app. Applying it is a no-op; it *is* the phone."
  else
    log "# Generated by \`android-enforce --dump\` — the declared apps' current"
    log "# runtime permissions (the ones you set), notification access and the link"
    log "# domains you chose to open in the app."
  fi
  log "#"
  log "# Every declared app is listed — one with nothing declared is an empty"
  log "# block — so the file is the whole install list, not only the configured"
  log "# part of it."
  log "#"
  log "# Use it as:  apps = import ./android-app-state.nix;"
  log "{"

  while IFS= read -r app; do
    [[ -z "$app" ]] && continue
    body=""

    # Runtime permissions (POST_NOTIFICATIONS is declared under notifications).
    if [[ "$DUMP_ALL" == 1 ]]; then
      # Every permission the app holds right now, not only the ones you answered
      # a prompt for — that is what makes this file a description of the phone
      # rather than a list of exceptions to it.
      perms="$(live_runtime_perms "$app" | awk '$2 == "true" { print $1, $2 }')"
    else
      perms="$(user_set_perms "$app")"
    fi
    while read -r perm granted; do
      [[ -z "$perm" ]] && continue
      [[ "$perm" == "android.permission.POST_NOTIFICATIONS" ]] && continue
      if [[ "$granted" == "true" ]]; then
        body+="    permissions.\"$perm\" = \"allow\";"$'\n'
      else
        body+="    permissions.\"$perm\" = \"deny\";"$'\n'
      fi
    done <<<"$perms"

    # Notifications: POST_NOTIFICATIONS, plus the notification-access components
    # this app currently has enabled (one list, not one line per component).
    if [[ "$DUMP_ALL" == 1 ]]; then
      enabled="$(live_runtime_perms "$app" | awk '$1 == "android.permission.POST_NOTIFICATIONS" { print $2; exit }')"
    else
      enabled="$(live_runtime_perms "$app" | awk '$1 == "android.permission.POST_NOTIFICATIONS" && $3 ~ /USER_SET/ { print $2; exit }')"
    fi
    if [[ -n "$enabled" ]]; then
      body+="    notifications.enabled = $enabled;"$'\n'
    fi
    listeners=""
    while IFS= read -r comp; do
      [[ -z "$comp" ]] && continue
      listeners+=" \"$comp\""
    done < <(app_listeners "$app")
    if [[ -n "$listeners" ]]; then
      body+="    notifications.listeners = [$listeners ];"$'\n'
    fi

    # App ops. `--dump-all` keeps the ones Settings exposes that are granted
    # right now; platform-internal ops are never dumped, because
    # android-enforce does not manage them either. A plain --dump only includes
    # them when asked with --dump-appops (appops reports targetSdk-derived modes
    # for every app, which would drown the mirror).
    if [[ "$DUMP_APP_OPS" == 1 || "$DUMP_ALL" == 1 ]]; then
      while read -r op mode; do
        [[ -z "$op" ]] && continue
        if [[ "$DUMP_ALL" == 1 ]]; then
          case "$mode" in
            allow | foreground) ;;
            *) continue ;;
          esac
        fi
        body+="    appops.$op = \"$mode\";"$'\n'
      done < <(if [[ "$DUMP_ALL" == 1 ]]; then live_appop_curated "$app"; else live_appop_modes "$app"; fi)
    fi

    # Open-by-default links: only the user's choices. A domain listed under
    # "Disabled" and link handling allowed is the device default, so it is not
    # dumped; an *enabled* domain (or a disabled master switch) is.
    if [[ "$(live_link_allowed "$app")" == "false" ]]; then
      body+="    links.open = false;"$'\n'
    fi
    while read -r domain state; do
      [[ -z "$domain" || "$state" != "enabled" ]] && continue
      body+="    links.domains.\"$domain\" = \"allow\";"$'\n'
    done < <(live_link_state "$app")

    if [[ -z "$body" ]]; then
      # Declared with nothing said about it: the app-id is the declaration, so
      # it is still listed — dropping it here would uninstall the app.
      log "  \"$app\" = { };"
      continue
    fi
    log "  \"$app\" = {"
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      log "$line"
    done <<<"$body"
    log "  };"
  done < <(cfg_apps)

  log "}"
}

# --- main ------------------------------------------------------------------
case "$MODE" in

  effective)
    jq '.' "$CONFIG"
    ;;
  dump)
    # Read once, then render from the snapshot.
    load_config "$CONFIG" "$RECOMMENDED"
    if ! prefetch_live "$(cfg_apps)"; then
      exit 1
    fi
    dump_nix
    ;;
  *)
    # The list to walk is known before anything is read, so every answer the
    # walk will ask for is fetched in one root round trip; the changes it then
    # decides on are applied in a second one.
    load_config "$CONFIG" "$RECOMMENDED"
    if [[ -n "$ONLY" ]]; then
      walk_apps="$ONLY"
    else
      walk_apps="$(managed_apps)"
    fi
    if ! prefetch_live "$walk_apps"; then
      log "!! nothing could be read from the device" >&2
      exit 1
    fi
    while IFS= read -r app; do
      [[ -z "$app" ]] && continue
      enforce_app "$app"
    done <<<"$walk_apps"
    flush_queue

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
