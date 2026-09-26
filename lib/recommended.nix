# Bundle the per-app `recommended.json` sidecars into the single index that
# `android-enforce --recommended` reads.
#
# A sidecar is a curated opinion that ships next to the app: what that app
# should be allowed to do, independent of any one phone. `recommended` mode
# applies it as the baseline, the consumer's config on top, and takes away
# whatever is left unlisted.
#
# The apps live in the by-name layout (pkgs/by-name/<shard>/<app-id>/), so the
# sidecar is found by walking that tree — the app id is the directory name.
{ pkgs }:

let
  lib = pkgs.lib;

  byNameDir = ../pkgs/by-name;

  appDirs = lib.concatMapAttrs
    (shard: _:
      lib.mapAttrs'
        (app: _: lib.nameValuePair app "${byNameDir}/${shard}/${app}")
        (lib.filterAttrs (_: type: type == "directory") (builtins.readDir "${byNameDir}/${shard}")))
    (lib.filterAttrs (_: type: type == "directory") (builtins.readDir byNameDir));

  sidecar = app: "${appDirs.${app}}/recommended.json";
  curated = lib.filterAttrs (app: _: builtins.pathExists (sidecar app)) appDirs;
in
pkgs.writeText "aliyss-android-pkgs-recommended.json" (
  builtins.toJSON (lib.mapAttrs (app: _: builtins.fromJSON (builtins.readFile (sidecar app))) curated)
)
