# Bundle the per-app `recommended.json` sidecars into the single index that
# `android-enforce --recommended` reads.
#
# A sidecar is a curated opinion that ships next to the app: what that app
# should be allowed to do, independent of any one phone. `recommended` mode
# applies it as the baseline, the consumer's config on top, and takes away
# whatever is left unlisted.
{ pkgs }:

let
  lib = pkgs.lib;

  appDirs = lib.concatMapAttrs
    (category: _:
      lib.mapAttrs'
        (app: _: lib.nameValuePair app "${../pkgs}/${category}/${app}")
        (lib.filterAttrs (_: type: type == "directory") (builtins.readDir "${../pkgs}/${category}")))
    (lib.filterAttrs (_: type: type == "directory") (builtins.readDir ../pkgs));

  sidecar = app: "${appDirs.${app}}/recommended.json";
  curated = lib.filterAttrs (app: _: builtins.pathExists (sidecar app)) appDirs;
in
pkgs.writeText "aliyss-android-pkgs-recommended.json" (
  builtins.toJSON (lib.mapAttrs (app: _: builtins.fromJSON (builtins.readFile (sidecar app))) curated)
)
