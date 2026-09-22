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
#     apps = [ "com.darkempire78.opencalculator" ];
#   };
#
# `enable` defaults to false: the module is opt-in, so importing it in a shared
# module list is harmless on hosts that install nothing.
#
# On every switch (after linkGeneration):
#   - declared apps are built from `flakePath` and pm-installed as root through
#     install.sh -d. An app that is already installed is skipped (no rebuild),
#     so the list says what should be present rather than "install now"; a slow
#     install is bounded so a Google Play Protect block is reported instead of
#     hanging the switch;
#   - apps that left the list are uninstalled (state tracked in
#     ~/.local/state/aliyss-android-pkgs);
#   - declared per-app state (runtime permissions, notifications, app ops and
#     open-by-default link handling) is enforced by android-enforce, after the
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
  # Rendered for android-enforce: the declared apps plus their per-app state.
  enforceConfig = pkgs.writeText "aliyss-android-pkgs-enforce.json" (builtins.toJSON {
    apps = cfg.apps;
    permissions = cfg.permissions;
    notifications = cfg.notifications;
    appops = cfg.appops;
    links = cfg.links;
    mode = cfg.mode;
    appModes = cfg.appModes;
  });
  appList = lib.concatStringsSep " " cfg.apps;
in
{
  options.aliyss.androidPkgs = {
    enable = lib.mkEnableOption "declarative Android app installs (aliyss-android-pkgs)";

    apps = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "com.darkempire78.opencalculator" ];
      description = ''
        Android apps to install on the phone, by app-id from the
        aliyss-android-pkgs flake input (e.g. "com.darkempire78.opencalculator").
        Built + pm-installed (as root) on every home-manager switch; apps that
        are already installed are skipped, and apps removed from the list are
        uninstalled.
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

    permissions = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf (lib.types.enum [ "allow" "deny" ]));
      default = { };
      example = { "com.whatsapp" = { "android.permission.CAMERA" = "deny"; }; };
      description = ''
        Runtime permissions to enforce per app:
        permissions."<app-id>"."<permission>" = "allow" | "deny", applied with
        `pm grant` / `pm revoke` as root on every switch.

        These are overrides, not a full desired state: a permission that is not
        listed is never granted or revoked, and an app with no entry is left
        alone — so a dump of what the phone already does
        (`android-enforce --dump`) applies as a no-op.
      '';
    };

    notifications = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
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
              Notification-access components to enable; the app's components that
              are not listed are switched off. Leave unset to leave this app's
              notification access alone.
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
      });
      default = { };
      description = ''
        Notification behaviour to enforce per app, e.g.
        notifications."com.whatsapp".enabled = false;. Fields left unset are
        untouched. `dnd` and `bubbles` are applied but cannot be read back, so
        they are not part of drift checks.
      '';
    };
    appops = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf (lib.types.enum [ "allow" "deny" "ignore" "foreground" "default" ]));
      default = { };
      example = { "com.whatsapp" = { "RUN_ANY_IN_BACKGROUND" = "deny"; }; };
      description = ''
        App ops to enforce per app:
        appops."<app-id>"."<OP>" = "allow" | "deny" | "ignore" | "foreground" | "default",
        applied with `appops set` as root on every switch. `"default"` resets the
        op to the platform mode.

        Use this for the toggles Android exposes outside runtime permissions, e.g.
        RUN_ANY_IN_BACKGROUND (background activity), REQUEST_INSTALL_PACKAGES
        (install unknown apps), SYSTEM_ALERT_WINDOW (display over other apps),
        WRITE_SETTINGS (modify system settings). Like `permissions`, an op that is
        not listed is left alone.
      '';
    };

    links = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          open = lib.mkOption {
            type = lib.types.nullOr lib.types.bool;
            default = null;
            description = ''
              Master open-by-default switch for the app (link handling allowed).
              null leaves it alone.
            '';
          };
          domains = lib.mkOption {
            type = lib.types.attrsOf (lib.types.enum [ "allow" "deny" ]);
            default = { };
            example = { "wa.me" = "allow"; };
            description = ''
              Per-domain open-by-default state for the verified app links the app
              declares (`pm set-app-links-user-selection`). A domain the app does
              not declare is reported and fails the switch instead of silently
              doing nothing.
            '';
          };
        };
      });
      default = { };
      description = ''
        Android app-link (open by default) state per app. `open` is the switch app
        info shows as "Open by default"; `domains` picks which of the app verified
        domains open in it. Both are read back from the device, so they take part
        in `android-enforce --check` drift reporting.
      '';
    };
    mode = lib.mkOption {
      type = lib.types.enum [ "overrides" "managed" ];
      default = "overrides";
      description = ''
        How the per-app state below is read.

        - "overrides" (default): the config is additions only. An app with no
          entry is untouched and an unlisted permission, app op or link domain
          is never touched.
        - "managed": the config is the whole intent for every declared app, so
          anything granted but not listed is taken away. It only removes grants
          (an app op that is unset stays at its platform default), it leaves
          POST_NOTIFICATIONS to notifications.enabled so that a managed switch
          does not silence every app without a notification entry, and of the
          app ops only the toggles Android Settings exposes take part.
      '';
    };

    appModes = lib.mkOption {
      type = lib.types.attrsOf (lib.types.enum [ "overrides" "managed" ]);
      default = { };
      example = { "com.example.app" = "managed"; };
      description = ''
        Per-app override of `mode`, so managed can be rolled out one app at a
        time — e.g. managed globally with a few apps left as overrides.
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
        log "Installing declared Android apps (aliyss.androidPkgs): ${lib.concatStringsSep ", " cfg.apps}"
        if ! ${installerBin} -d -f "${cfg.flakePath}" $curr; then
          warn "one or more apps failed to install (Play Protect block? see above) — fix and re-run update-home"
          exit 1
        fi
      fi
    '';

    # Declared per-app state: runtime permissions + notification access. Runs
    # after the installs so a freshly installed app is configured in the same
    # switch, and is idempotent (android-enforce diffs against the device).
    home.activation.enforceAndroidPkgsState =
      lib.hm.dag.entryAfter [ "installAndroidPkgs" ] ''
        log() { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }

        log "Enforcing declared app state (permissions, notifications, app ops, links)"
        if ! ${enforceBin} --on-device --config ${enforceConfig}; then
          echo "!! android-enforce failed — fix the declaration and re-run update-home" >&2
          exit 1
        fi
      '';
  };
}
