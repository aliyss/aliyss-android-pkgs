{ pkgs }:

let
  lib = pkgs.lib;
  fetchApk = pkgs.callPackage ../lib/fetchApk.nix { };

  pkgsDir = ./.;

  # The tree is laid out by name: pkgs/by-name/<shard>/<app-id>/package.nix.
  # The app id is the directory name, so a package is discovered by walking
  # rather than listed anywhere. shard_of (below) is the Nix twin of
  # scripts/layout.py's shard_for — keep the two in step; tests/test_layout.py
  # pins the rule and the structural tests walk the same layout.
  byNameDir = pkgsDir + "/by-name";

  # Lowercase and drop punctuation, i.e. layout.py's `_ALNUM` regex: the shard
  # key ignores case and separators.
  squish = s:
    let
      keep = c: if builtins.match "[A-Za-z0-9]" c != null then lib.toLower c else "";
    in
    lib.concatStrings (map keep (lib.stringToCharacters s));

  shardOf = appId:
    let
      parts = lib.splitString "." appId;
      raw = if lib.length parts > 2 then lib.elemAt parts 1 else lib.head parts;
      label = squish raw;
      # S.N.A.K.E -> "N" is too short; fall back to the id, as layout.py does.
      full = if builtins.stringLength label < 2 then squish appId else label;
    in
    builtins.substring 0 2 full;

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
  hasPin = appDir:
    let
      pin = builtins.fromJSON (builtins.readFile (appDir + "/hashes.json"));
    in
    (pin.version or "") != "";

  appPaths = lib.flatten (lib.mapAttrsToList (shard: _:
    let
      apps = lib.filterAttrs (_: type: type == "directory")
        (builtins.readDir (byNameDir + "/${shard}"));
    in
    lib.mapAttrsToList (appId: _:
      lib.nameValuePair (sanitizeName appId) (byNameDir + "/${shard}/${appId}/package.nix"))
      apps)
    (lib.filterAttrs (_: type: type == "directory") (builtins.readDir byNameDir)));
  pinnedPaths = lib.filter (entry: hasPin (dirOf entry.value)) appPaths;
in
lib.listToAttrs (map (entry: {
  inherit (entry) name;
  value = pkgs.callPackage entry.value { inherit fetchApk; };
}) pinnedPaths)
