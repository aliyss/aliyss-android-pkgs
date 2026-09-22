{
  pkgs,
  config,
  lib,
  # The aliyss-android-pkgs flake input itself — the module ships with that
  # flake, so the installer package it exposes is not reachable any other way.
  # Consumers that pass their flake inputs to modules (home-manager
  # `extraSpecialArgs = inputs`) already have this in scope.
  aliyss-android-pkgs,
  ...
}:

# Declarative Android app installs for the phone (aliyss.androidPkgs), shipped
# by the aliyss-android-pkgs flake so a consumer only declares the app list.
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
#     install.sh -d; a slow install is bounded so a Google Play Protect block is
#     reported instead of hanging the switch;
#   - apps that left the list are uninstalled (state tracked in
#     ~/.local/state/aliyss-android-pkgs);
#   - a failed install fails the switch loudly; failed removals only warn.
let
  cfg = config.aliyss.androidPkgs;
  installer = aliyss-android-pkgs.packages.${pkgs.system}.android-install;
  # The activation must call the installer by store path — the generated
  # activation script's PATH has no ~/.nix-profile/bin (the ~/.local/bin
  # wrapper is created post-switch by ensure-nix-wrappers.sh).
  installerBin = "${installer}/bin/android-install";
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
        Built + pm-installed (as root) on every home-manager switch; apps
        removed from the list are uninstalled.
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
  };

  config = lib.mkIf cfg.enable {
    # The installer, linked into ~/.local/bin by ensure-nix-wrappers.sh (giving
    # the phone the plain `android-install` command).
    home.packages = [ installer ];

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
  };
}
