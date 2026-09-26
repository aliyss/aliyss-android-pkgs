#!/usr/bin/env bash
# The android-enforce walk, off the device.
#
# --print-effective (tests/enforce_config_test.sh) covers how a config is folded;
# this covers what the walk then *decides*. android-enforce reads the device
# once through a single root script and applies through a second; both scripts
# are handed to `su`. Here a fake `su` runs them locally and the fake
# dumpsys/appops/pm/settings on $AS_SYSTEM_PATH answer from fixtures, so the
# walk's reads, comparisons and drift report are exercised with no device and no
# root.
#
# It is the regression guard for two silent bugs:
#   * the global/per-app `mode` record was dropped (empty field collapsed by
#     `read` with a whitespace IFS), so a `managed` posture never applied; and
#   * the notification-listener list was looked up under the wrong snapshot key,
#     so enabled listeners read as drift.
#
#   bash tests/enforce_walk_test.sh
#   ENFORCE=/nix/store/.../bin/android-enforce bash tests/enforce_walk_test.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(dirname "$here")"
if [[ -z "${ENFORCE:-}" ]]; then
  ENFORCE="$(nix build --no-link --print-out-paths "$repo#android-enforce" | tail -1)/bin/android-enforce"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Fakes on both sides: `su` is found at process start, the system binaries are
# found by the generated root scripts (whose PATH is $AS_SYSTEM_PATH).
fakebin="$tmp/bin"
fixtures="$tmp/fixtures"
mkdir -p "$fakebin" "$fixtures"
cp "$here"/fake/* "$fakebin/"
chmod +x "$fakebin"/*
# The generated root scripts replace PATH with $AS_SYSTEM_PATH, so it has to
# keep the real PATH *after* the fakes (the fakes are `#!/usr/bin/env bash`).
export AS_FAKE_DIR="$fixtures"
export AS_SYSTEM_PATH="$fakebin:$PATH"

fails=0
ok() { printf 'ok: %s\n' "$*"; }
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  fails=$((fails + 1))
}

# Run --check; stdout in WALK_OUT, exit status in WALK_RC.
run_check() { # $1 = config path
  if WALK_OUT="$(PATH="$fakebin:$PATH" "$ENFORCE" --on-device --config "$1" --check 2>&1)"; then
    WALK_RC=0
  else
    WALK_RC=$?
  fi
}

expect_contains() { # $1 = haystack, $2 = needle, $3 = what
  if grep -qF -- "$2" <<<"$1"; then
    ok "$3"
  else
    fail "$3 (missing: $2)"
    printf '%s\n' "$1" | sed 's/^/    /' >&2
  fi
}

# ---------------------------------------------------------------- fixtures --
# The app's package dump, app-op listing and app links, plus the global
# notification-listener setting; each case rewrites the ones it cares about.
# The dump carries the "runtime permissions:" section the walk parses.
cat >"$fixtures/com.example.app.pkg" <<'EOF'
Packages:
  Package [com.example.app]
    runtime permissions:
      android.permission.CAMERA: granted=false, flags=[]

EOF
: >"$fixtures/com.example.app.links"
: >"$fixtures/listeners"

# A managed app with an op explicitly allowed: the posture says revoke it.
echo 'MANAGE_EXTERNAL_STORAGE: allow' >"$fixtures/com.example.app.appops"

# 1. The managed posture applies: an explicit grant is drift. A dropped `mode`
#    record would make this walk a no-op and report OK.
printf '{"mode":"managed","apps":{"com.example.app":{}}}\n' >"$tmp/managed.json"
run_check "$tmp/managed.json"
if [[ "$WALK_RC" == 1 ]]; then ok "a managed posture is enforced (exit 1)"; else fail "managed posture not enforced (exit $WALK_RC)"; fi
expect_contains "$WALK_OUT" "MANAGE_EXTERNAL_STORAGE should be deny (managed)" "an allowed managed op is reported as drift"

# 2. The same walk on a compliant device is clean.
echo 'MANAGE_EXTERNAL_STORAGE: deny' >"$fixtures/com.example.app.appops"
run_check "$tmp/managed.json"
if [[ "$WALK_RC" == 0 ]]; then ok "a compliant managed device passes (exit 0)"; else fail "compliant device reported drift (exit $WALK_RC)"; fi
expect_contains "$WALK_OUT" "OK:" "a compliant walk reports OK"

# 3. A declared runtime permission is compared against the device grant.
echo 'MANAGE_EXTERNAL_STORAGE: deny' >"$fixtures/com.example.app.appops"
printf '{"mode":"overrides","apps":{"com.example.app":{"permissions":{"android.permission.CAMERA":"allow"}}}}\n' >"$tmp/perm.json"
run_check "$tmp/perm.json"
if [[ "$WALK_RC" == 1 ]]; then ok "a permission mismatch drifts (exit 1)"; else fail "permission mismatch not reported (exit $WALK_RC)"; fi
expect_contains "$WALK_OUT" "android.permission.CAMERA should be allow" "a revoked permission declared allow is drift"

# 4. A declared notification listener that is enabled reads as ok, not drift.
printf 'com.example.app/.Listener\n' >"$fixtures/listeners"
printf '{"mode":"overrides","apps":{"com.example.app":{"permissions":{"android.permission.CAMERA":"deny"},"notifications":{"listeners":["com.example.app/.Listener"]}}}}\n' >"$tmp/listener.json"
run_check "$tmp/listener.json"
expect_contains "$WALK_OUT" "ok: listener com.example.app/.Listener enabled" "an enabled declared listener is not drift"

# 5. A declared listener that is not enabled is drift.
printf 'other.app/.Listener\n' >"$fixtures/listeners"
run_check "$tmp/listener.json"
if [[ "$WALK_RC" == 1 ]]; then ok "a missing listener drifts (exit 1)"; else fail "missing listener not reported (exit $WALK_RC)"; fi
expect_contains "$WALK_OUT" "listener com.example.app/.Listener should be enabled" "a disabled declared listener is drift"

if [[ "$fails" != 0 ]]; then
  printf '\n!! %d walk test(s) failed\n' "$fails" >&2
  exit 1
fi
printf '\nAll walk tests passed.\n'
