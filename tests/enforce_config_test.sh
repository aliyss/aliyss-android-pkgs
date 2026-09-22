#!/usr/bin/env bash
# Config shapes of android-enforce.
#
# The per-app layout (`apps.<app-id>` with the app's state inside) is the
# canonical one; the older flat layout (an `apps` array plus one map per kind)
# has to mean exactly the same thing, and a curated baseline
# (`recommended.json`, shipped per app and passed as one index) has to sit under
# the config — including under the nulls the home-manager module renders for
# every field an app leaves unset, which must not wipe the curated value.
#
# `android-enforce --print-effective` prints the config after all of that has
# been folded together, so this needs no device and no root.
#
#   bash tests/enforce_config_test.sh
#   ENFORCE=/nix/store/.../bin/android-enforce bash tests/enforce_config_test.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(dirname "$here")"
if [[ -z "${ENFORCE:-}" ]]; then
  ENFORCE="$(nix build --no-link --print-out-paths "$repo#android-enforce" | tail -1)/bin/android-enforce"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fails=0
ok() { printf 'ok: %s\n' "$*"; }
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  fails=$((fails + 1))
}

# Canonical config of a fixture, optionally with a curated index.
effective() {
  if [[ -n "${2:-}" ]]; then
    "$ENFORCE" --config "$1" --recommended "$2" --print-effective
  else
    "$ENFORCE" --config "$1" --print-effective
  fi
}

# 1. The flat layout and the per-app layout must fold to the same config.
cat >"$tmp/legacy.json" <<'JSON'
{"mode":"managed",
 "apps":["com.discord","com.whatsapp","com.github.android"],
 "permissions":{"com.discord":{"android.permission.CAMERA":"deny"}},
 "notifications":{"com.discord":{"enabled":false,"listeners":null,"dnd":null,"bubbles":null}},
 "appops":{"com.whatsapp":{"RUN_ANY_IN_BACKGROUND":"allow"}},
 "links":{"com.github.android":{"open":false,"domains":{}}},
 "appModes":{"com.whatsapp":"managed"}}
JSON
cat >"$tmp/per-app.json" <<'JSON'
{"mode":"managed",
 "apps":{
   "com.discord":{"permissions":{"android.permission.CAMERA":"deny"},
                  "notifications":{"enabled":false}},
   "com.whatsapp":{"mode":"managed","appops":{"RUN_ANY_IN_BACKGROUND":"allow"}},
   "com.github.android":{"links":{"open":false}}}}
JSON
effective "$tmp/legacy.json" | jq -S . >"$tmp/legacy.canon"
effective "$tmp/per-app.json" | jq -S . >"$tmp/per-app.canon"
if diff -u "$tmp/legacy.canon" "$tmp/per-app.canon"; then
  ok "the flat layout means the same as the per-app layout"
else
  fail "the flat layout and the per-app layout differ"
fi

# 2. Everything is per app, including the mode.
if jq -e '
    .mode == "managed"
    and .apps["com.whatsapp"].mode == "managed"
    and .apps["com.discord"].permissions["android.permission.CAMERA"] == "deny"
    and .apps["com.discord"].notifications.enabled == false
    and .apps["com.whatsapp"].appops["RUN_ANY_IN_BACKGROUND"] == "allow"
    and .apps["com.github.android"].links.open == false
    and .apps["com.discord"].mode == "managed"
  ' "$tmp/per-app.canon" >/dev/null; then
  ok "declared state is reachable per app"
else
  fail "the canonical config does not carry the declared state per app"
fi

# 3. A curated baseline fills in what the module left null.
printf '{"com.example.app":{"notifications":{"enabled":false},"appops":{"RUN_ANY_IN_BACKGROUND":"deny"}}}\n' >"$tmp/index.json"
cat >"$tmp/rec.json" <<'JSON'
{"mode":"managed",
 "apps":{"com.example.app":{"mode":"recommended",
   "notifications":{"enabled":null,"listeners":null,"dnd":null,"bubbles":null},
   "appops":{}}}}
JSON
effective "$tmp/rec.json" "$tmp/index.json" | jq -S . >"$tmp/rec.canon"
if jq -e '
    .apps["com.example.app"].notifications.enabled == false
    and .apps["com.example.app"].appops["RUN_ANY_IN_BACKGROUND"] == "deny"
  ' "$tmp/rec.canon" >/dev/null; then
  ok "a curated baseline survives the module's nulls"
else
  fail "the curated baseline was wiped by null fields"
fi

# 4. The config wins over the curated baseline, field by field.
cat >"$tmp/rec-override.json" <<'JSON'
{"mode":"managed",
 "apps":{"com.example.app":{"mode":"recommended","notifications":{"enabled":true}}}}
JSON
effective "$tmp/rec-override.json" "$tmp/index.json" | jq -S . >"$tmp/rec-override.canon"
if jq -e '
    .apps["com.example.app"].notifications.enabled == true
    and .apps["com.example.app"].appops["RUN_ANY_IN_BACKGROUND"] == "deny"
  ' "$tmp/rec-override.canon" >/dev/null; then
  ok "the config overrides the curated baseline per field"
else
  fail "the config did not override the curated baseline"
fi

# 5. The index never declares an app: a curated app that is not installed stays
#    uninstalled.
cat >"$tmp/not-declared.json" <<'JSON'
{"mode":"managed","apps":{"com.discord":{}}}
JSON
effective "$tmp/not-declared.json" "$tmp/index.json" | jq -S . >"$tmp/not-declared.canon"
if jq -e '(.apps | keys) == ["com.discord"]' "$tmp/not-declared.canon" >/dev/null; then
  ok "the curated index never adds an app to the install list"
else
  fail "the curated index added an undeclared app"
fi

# 6. Declaring nothing is valid (an empty apps block, e.g. a host with no apps).
printf '{"mode":"overrides","apps":{}}\n' >"$tmp/empty.json"
if jq -e '.apps == {} and .mode == "overrides"' <(effective "$tmp/empty.json") >/dev/null; then
  ok "an empty declaration is valid"
else
  fail "an empty declaration did not survive normalization"
fi

# 7. The app list is the declaration: ids from the flat array are kept, and the
#    per-app keys are what runs.
if jq -e '(.apps | keys) == ["com.discord", "com.github.android", "com.whatsapp"]' \
  "$tmp/legacy.canon" >/dev/null; then
  ok "the app list comes from the declaration"
else
  fail "the app list is wrong"
fi

if [[ "$fails" != 0 ]]; then
  printf '\n!! %d shape test(s) failed\n' "$fails" >&2
  exit 1
fi
printf '\nAll config shape tests passed.\n'
