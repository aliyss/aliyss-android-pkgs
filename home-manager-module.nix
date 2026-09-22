{
  pkgs,
  config,
  lib,
  # The aliyss-android-pkgs flake input itself — the module ships with that
  # flake, so the packages it exposes (the installer and the enforcer) are not
  # reachable any other way. Consumers that pass their flake inputs to modules
  # (home-manager `extraSpecialArgs = inputs`) already have this in scope.
  aliyss-android-pkgs,
  ...
}:

# Declarative Android app installs for the phone (aliyss.androidPkgs), shipped
# by the aliyss-android-pkgs flake so a consumer only declares what it wants.
#
# Wiring (phone host only — the activation installs system packages as root):
#
#   home-manager.sharedModules = [
#     inputs.aliyss-android-pkgs.homeManagerModules.${system}.default
#   ];
#
#   aliyss.androidPkgs = {
#     enable = true;
#     apps = {
#       "com.darkempire78.opencalculator" = { };
#       "com.whatsapp" = {
#         notifications.enabled = false;
#         appops.RUN_ANY_IN_BACKGROUND = "allow";
#       };
#     };
#   };
#
# `enable` defaults to false: the module is opt-in, so importing it in a shared
# module list is harmless on hosts that install nothing.
#
# `apps` is one place per app: the app-id is the key (an app-id that is not a
# key is not installed) and its block is that app's declared state — runtime
# permissions, notifications, app ops and open-by-default links. A list of
# app-ids is still accepted for apps with nothing declared about them, and the
# older flat layout (`apps` list + a `permissions`/`notifications`/`appops`/
# `links` map per kind) is gone: an app now has a single entry, so an app
# leaving the phone is one deletion rather than one per map.
#
# On every switch (after linkGeneration):
#   - declared apps are built from `flakePath` and pm-installed as root through
#     install.sh -d. An app that is already installed is skipped (no rebuild),
#     so the declaration says what should be present rather than "install now";
#     a slow install is bounded so a Google Play Protect block is reported
#     instead of hanging the switch;
#   - apps that left `apps` are uninstalled (state tracked in
#     ~/.local/state/aliyss-android-pkgs);
#   - the declared per-app state is enforced by android-enforce, after the
#     installs;
#   - a failed install/enforce fails the switch loudly; failed removals only
#     warn.
let
  cfg = config.aliyss.androidPkgs;
  installer = aliyss-android-pkgs.packages.${pkgs.system}.android-install;
  # The activation must call the tools by store path — the generated activation
  # script's PATH has no ~/.nix-profile/bin (the ~/.local/bin wrapper is
  # created post-switch by ensure-nix-wrappers.sh).
  installerBin = "${installer}/bin/android-install";
  enforce = aliyss-android-pkgs.packages.${pkgs.system}.android-enforce;
  enforceBin = "${enforce}/bin/android-enforce";
  # The curated per-app baselines (`recommended.json` sidecars) bundled into one
  # index: `recommended` mode applies them under this config, so the opinion
  # travels with the app instead of living in every consumer.
  recommended = aliyss-android-pkgs.packages.${pkgs.system}.android-recommended;
  recommendedIndex = "${recommended}";
  # `apps` accepts a list of app-ids (install, declare nothing) or the per-app
  # attrset, which is the canonical form and what `--dump` writes. Everything
  # below works on the attrset, so the key is the one declaration of an app.
  appBodies = if lib.isList cfg.apps then lib.genAttrs cfg.apps (_: { }) else cfg.apps;
  appIds = lib.attrNames appBodies;
  # Rendered for android-enforce: one block per declared app.
  enforceConfig = pkgs.writeText "aliyss-android-pkgs-enforce.json" (builtins.toJSON {
    mode = cfg.mode;
    apps = appBodies;
  });
  appList = lib.concatStringsSep " " appIds;
  # What the enforcement pass is about to do. Under `managed` the enforcer also
  # takes away grants the config does not list, so say so — and say what it
  # deliberately leaves alone, so the carve-outs are visible rather than
  # something to discover later.
  enforceNotice =
    "Enforcing declared app state (permissions, notifications, app ops, links)"
    + lib.optionalString (cfg.mode == "managed")
      " — managed: unlisted grants are taken away (platform-internal app ops and POST_NOTIFICATIONS excepted)"
    + lib.optionalString (cfg.mode == "recommended")
      " — recommended: each app's curated block + this config, everything else taken away";
  # What a single app may declare. Defaults are null rather than false/empty so
  # "unset" is distinguishable from "declared as off" — under `managed` that is
  # the difference between leaving a grant alone and taking it away.
  appOptions = {
    options = {
      mode = lib.mkOption {
        type = lib.types.nullOr (lib.types.enum [ "overrides" "managed" "recommended" ]);
        default = null;
        description = ''
          Per-app override of `mode`, so managed can be rolled out one app at a
          time (or a single app can take its curated block in `recommended`).
        '';
      };

      permissions = lib.mkOption {
        type = lib.types.attrsOf (lib.types.enum [ "allow" "deny" ]);
        default = { };
        example = { "android.permission.CAMERA" = "deny"; };
        description = ''
          Runtime permissions to enforce for this app:
          permissions."<permission>" = "allow" | "deny", applied with
          `pm grant` / `pm revoke` as root on every switch. A permission that is
          not listed is never granted or revoked.
        '';
      };

      notifications = lib.mkOption {
        type = lib.types.submodule {
          options = {
            enabled = lib.mkOption {
              type = lib.types.nullOr lib.types.bool;
              default = null;
              description = "Whether the app may post notifications (POST_NOTIFICATIONS).";
            };
            listeners = lib.mkOption {
              type = lib.types.nullOr (lib.types.listOf lib.types.str);
              default = null;
              example = [ "com.whatsapp/.NotificationListener" ];
              description = ''
                Notification-access components to enable; the app's components
                that are not listed are switched off. Leave unset to leave this
                app's notification access alone.
              '';
            };
            dnd = lib.mkOption {
              type = lib.types.nullOr lib.types.bool;
              default = null;
              description = "Exempt (true) or not (false) from Do Not Disturb.";
            };
            bubbles = lib.mkOption {
              type = lib.types.nullOr (lib.types.enum [ "none" "all" "selected" ]);
              default = null;
              description = "Bubble preference for the app's conversations.";
            };
          };
        };
        default = { };
        description = ''
          Notification behaviour to enforce for this app, e.g.
          notifications.enabled = false;. Fields left unset are untouched.
          `dnd` and `bubbles` are applied but cannot be read back, so they are
          not part of drift checks.
        '';
      };

      appops = lib.mkOption {
        type = lib.types.attrsOf (lib.types.enum [ "allow" "deny" "ignore" "foreground" "default" ]);
        default = { };
        example = { "RUN_ANY_IN_BACKGROUND" = "deny"; };
        description = ''
          App ops to enforce for this app:
          appops."<OP>" = "allow" | "deny" | "ignore" | "foreground" | "default",
          applied with `appops set` as root on every switch. `"default"` resets
          the op to the platform mode.

          Use this for the toggles Android exposes outside runtime permissions,
          e.g. RUN_ANY_IN_BACKGROUND (background activity),
          REQUEST_INSTALL_PACKAGES (install unknown apps), SYSTEM_ALERT_WINDOW
          (display over other apps), WRITE_SETTINGS (modify system settings).
          Like `permissions`, an op that is not listed is left alone.
        '';
      };

      links = lib.mkOption {
        type = lib.types.submodule {
          options = {
            open = lib.mkOption {
              type = lib.types.nullOr lib.types.bool;
              default = null;
              description = ''
                Open-by-default switch for this app (link handling allowed).
                null leaves it alone.
              '';
            };
            domains = lib.mkOption {
              type = lib.types.attrsOf (lib.types.enum [ "allow" "deny" ]);
              default = { };
              example = { "wa.me" = "allow"; };
              description = ''
                Per-domain open-by-default state for the verified app links the
                app declares (`pm set-app-links-user-selection`). A domain the
                app does not declare is reported and fails the switch instead of
                silently doing nothing.
              '';
            };
          };
        };
        default = { };
        description = ''
          Android app-link (open by default) state for this app. `open` is the
          switch app info shows as "Open by default"; `domains` picks which of
          the app verified domains open in it. Both are read back from the
          device, so they take part in `android-enforce --check` drift
          reporting.
        '';
      };
    };
  };
in
{
  options.aliyss.androidPkgs = {
    enable = lib.mkEnableOption "declarative Android app installs (aliyss-android-pkgs)";

    apps = lib.mkOption {
      type = lib.types.either (lib.types.listOf lib.types.str)
        (lib.types.attrsOf (lib.types.submodule appOptions));
      default = { };
      example = lib.literalExpression ''
        {
          "com.darkempire78.opencalculator" = { };
          "com.whatsapp" = {
            notifications.enabled = true;
            appops.RUN_ANY_IN_BACKGROUND = "allow";
          };
        }
      '';
      description = ''
        The Android apps this host declares, by app-id (e.g.
        "com.darkempire78.opencalculator"): the app-id is the key and its block
        is what is declared about it — `permissions`, `notifications`, `appops`,
        `links` and an optional per-app `mode`. An app with nothing to declare
        gets an empty block (`"com.app" = { };`).

        A plain list of app-ids is also accepted, for hosts that only want the
        installs and no state.

        These apps are built from the aliyss-android-pkgs flake input and
        pm-installed (as root) on every switch; apps that are already installed
        are skipped, and an app-id removed from `apps` is uninstalled — so this
        one option says what is installed and how it is configured.
      '';
    };

    flakePath = lib.mkOption {
      type = lib.types.path;
      default = "${config.home.homeDirectory}/.config/flake";
      defaultText = "~/.config/flake";
      description = ''
        Path to the dotfiles flake used to build app packages. Passed to
        `android-install -f` so it can `nix build <flake>#<app-attr>`.
      '';
    };

    mode = lib.mkOption {
      type = lib.types.enum [ "overrides" "managed" "recommended" ];
      default = "overrides";
      description = ''
        How the per-app state is read.

        - "overrides" (default): the config is additions only. An app with no
          state is untouched and an unlisted permission, app op or link domain
          is never touched.
        - "managed": the config is the whole intent for every declared app, so
          anything granted but not listed is taken away.
        - "recommended": managed, with each app's curated block from the
          aliyss-android-pkgs packages (recommended.json, next to its pin) as the
          baseline under this config — the packages carry the opinion and this
          file overrides it. An app with no curated block falls back to managed
          and --check reports it as uncurated.

        Either mode can be set for one app instead of all of them with an app's
        own `mode`, which is how a switch is rolled out.

        The managed-style modes only remove grants: an app op that is unset stays
        at its platform default, POST_NOTIFICATIONS stays with
        notifications.enabled (so a switch does not silence every app without a
        notification entry), and of the app ops only the toggles Android
        Settings exposes take part.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Both tools linked into ~/.local/bin by ensure-nix-wrappers.sh (giving the
    # phone the plain `android-install` / `android-enforce` commands).
    home.packages = [ installer enforce ];

    home.activation.installAndroidPkgs = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      state_file="$HOME/.local/state/aliyss-android-pkgs"
      mkdir -p "$(dirname "$state_file")"

      log() { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
      warn() { printf '\033[1;33m!! %s\033[0m\n' "$*" >&2; }

      # Previous run's declared apps (for uninstall-on-removal).
      prev=""
      if [ -f "$state_file" ]; then
        prev="$(cat "$state_file")"
      fi
      # App-ids are safe for shell interpolation (Android package names are
      # [a-zA-Z0-9._]).
      curr="${appList}"

      # Uninstall apps that were declared before but are gone from the list.
      if [ -n "$prev" ]; then
        for id in $prev; do
          case " $curr " in
            *" $id "*) : ;;
            *)
              log "Uninstalling removed app: $id"
              ${installerBin} -d -f "${cfg.flakePath}" -u "$id" \
                || warn "could not uninstall $id (already gone?)"
              ;;
          esac
        done
      fi

      # Record before installing, so an interrupted run re-runs cleanly.
      printf '%s\n' $curr >"$state_file"

      if [ -n "$curr" ]; then
        log "Installing declared Android apps (aliyss.androidPkgs): ${lib.concatStringsSep ", " appIds}"
        if ! ${installerBin} -d -f "${cfg.flakePath}" $curr; then
          warn "one or more apps failed to install (Play Protect block? see above) — fix and re-run update-home"
          exit 1
        fi
      fi
    '';

    # Declared per-app state: runtime permissions, notifications, app ops and
    # open-by-default links. Runs after the installs so a freshly installed app
    # is configured in the same switch, and is idempotent (android-enforce diffs
    # against the device).
    home.activation.enforceAndroidPkgsState =
      lib.hm.dag.entryAfter [ "installAndroidPkgs" ] ''
        log() { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }

        log "${enforceNotice}"
        if ! ${enforceBin} --on-device --recommended ${recommendedIndex} --config ${enforceConfig}; then
          echo "!! android-enforce failed — fix the declaration and re-run update-home" >&2
          exit 1
        fi
      '';
  };
}
