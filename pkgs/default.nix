{ pkgs }:

let
  lib = pkgs.lib;
  fetchApk = pkgs.callPackage ../lib/fetchApk.nix { };

  pkgsDir = ./.;

  # <category>/<app-id>/package.nix
  entries = lib.filterAttrs (_: type: type == "directory")
    (builtins.readDir pkgsDir);

  # Convert "com.spotify.music" -> "com-spotify-music" for clean attribute access.
  # Nix attribute names cannot start with a digit; a few Android package ids do
  # (e.g. the game "1.2.3"), so prefix those defensively.
  sanitizeName = name:
    let
      s = lib.replaceStrings [ "." ] [ "-" ] name;
    in
    if builtins.match "[0-9].*" s != null then "pkg-${s}" else s;

  # A package that was seeded (from verified-apps) but not yet pinned by
  # scripts/update.py has no version/hash in hashes.json and would fail to
  # evaluate (no hash -> fetchApk assert). Exclude those from the package set
  # so `nix flake check` stays green; update.py still discovers them and adds
  # them automatically once a version is pinned.
  hasPin = path:
    let
      pin = builtins.fromJSON (builtins.readFile (dirOf path + "/hashes.json"));
    in
    (pin.version or "") != "";

  appPaths = lib.flatten (lib.mapAttrsToList (category: _:
    let
      apps = lib.filterAttrs (_: type: type == "directory")
        (builtins.readDir (pkgsDir + "/${category}"));
    in
    lib.mapAttrsToList (appId: _:
      lib.nameValuePair (sanitizeName appId)
        (pkgsDir + "/${category}/${appId}/package.nix"))
      apps)
    entries);
  pinnedPaths = lib.filter (entry: hasPin entry.value) appPaths;
in
lib.listToAttrs (map (entry: {
  inherit (entry) name;
  value = pkgs.callPackage entry.value { inherit fetchApk; };
}) pinnedPaths)