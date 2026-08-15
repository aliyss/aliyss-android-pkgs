# A fixed-output derivation builder that downloads an Android APK with
# `apkeep` and verifies it against a hash selected for the host system.
#
# An APK's content (and hence its Nix hash) depends on the version, the source
# and the Android ABI it was built for. The `archs` map pins, per Nix system,
# which architecture to fetch and the exact hash of that artifact:
#
#   fetchApk {
#     pname   = "spotify";
#     appId   = "com.spotify.music";
#     version = "9.1.72.1891";
#     archs = {
#       x86_64-linux = { archStr = "x86_64";    hash = "sha256-..."; };
#       aarch64-linux = { archStr = "arm64-v8a"; hash = "sha256-..."; };
#     };
#     license = "unfree";
#   }
#
# If an app ships a single universal APK (the common case), omit `archs` and
# pass `hash` directly:
#
#   fetchApk { pname = "signal"; appId = "..."; version = "8.22.2"; hash = "..."; }
#
# For large repositories the archs/hash pins are usually generated into a
# `hashes.json` sidecar next to `package.nix` (see the bundled examples).
#
# Google Play / Aurora builds additionally require credentials:
#
#   fetchApk {
#     ...
#     source          = "google-play";      # alias "aurora" also accepted
#     googleEmail     = "you@gmail.com";
#     googleAuthToken = "ya29.a0...";       # token dispensed by Aurora Store
#     # or: googleAasToken = "...";         # long-lived AAS token
#     acceptTos       = true;
#   }
#
# F-Droid apps are fetched deterministically: the repository index publishes
# the exact file name and sha256 of every APK, so we download `<repoUrl>/<apkName>`
# directly with `outputHashMode = "flat"` (the index hash IS the build hash).
# No apkeep, no version negotiation - the pinned URL+hash always match.
#
#   fetchApk {
#     pname    = "hyle";
#     appId    = "de.jepfa.hyle_x";
#     source   = "f-droid";
#     repoUrl  = "https://f-droid.org/repo";   # default
#     apkName  = "de.jepfa.hyle_x_1010003.apk"; # from the index (hashes.json)
#     version  = "1.1.0";
#     hash     = "sha256-...";                 # flat file hash from the index
#   }
#
{ lib, stdenv, stdenvNoCC, apkeep, cacert, curl }:

{ pname
, appId
, version
, archs ? { }
  # Fallback for apps shipping a single universal APK; used when the current
  # system is not present in `archs`.
, hash ? null
, source ? "apk-pure"
  # Comma separated extra options passed to apkeep (`-o`), e.g.
  #   "apkarch=arm64-v8a,tier=1"               (apk-pure)
  #   "device=ad_g3_pro,locale=es_MX"          (google-play)
  #   "split_apk=true"                         (google-play)
, sourceOptions ? ""
  # Google Play / Aurora credentials (optional; only used if set).
, googleEmail ? null
, googleAasToken ? null
, googleAuthToken ? null
, acceptTos ? false
  # F-Droid only: base URL of the F-Droid-format repo and the exact file name
  # of the APK inside it (both published by the repo's signed index).
, repoUrl ? "https://f-droid.org/repo"
, apkName ? null
  # "free", "unfree", or an explicit license value. Defaults to free so that
  # only genuinely proprietary apps (e.g. from Play Store) opt into `unfree`,
  # mirroring the nixpkgs convention (meta.license / allowUnfree).
, license ? "free"
, meta ? { }
}:

let
  system = stdenv.hostPlatform.system;

  # Choose the architecture pin for this host. Fall back to any pinned
  # "universal" entry (a single artifact shared by every system) and finally to
  # the `hash` argument given directly for single-APK apps.
  universalEntry = lib.findFirst
    (e: (e.hash or null) != null)
    null
    (lib.filter (e: (e.archStr or "") == "universal") (lib.attrValues archs));

  targetArch =
    if archs ? ${system} then archs.${system}
    else if universalEntry != null then universalEntry
    else { archStr = "universal"; hash = hash; };

  selectedHash = if (targetArch.hash or null) != null then targetArch.hash else hash;
  selectedArchStr = targetArch.archStr or "universal";

  # Normalise common aliases onto apkeep's canonical `-d` source names.
  sourceNames = {
    apk-pure = "apk-pure";
    apkpure = "apk-pure";
    "apk-pure.com" = "apk-pure";
    google-play = "google-play";
    googleplay = "google-play";
    play = "google-play";
    aurora = "google-play";
    f-droid = "f-droid";
    fdroid = "f-droid";
    huawei-app-gallery = "huawei-app-gallery";
    huawei = "huawei-app-gallery";
  };
  normalizedSource = sourceNames.${source} or source;

  # F-Droid apps are fetched straight from the repo by exact file name; the
  # flat hash from the signed index is the build hash, so no apkeep at all.
  isFdroid = normalizedSource == "f-droid";

  # Only APKPure lets apkeep pin an exact version; Play-style sources
  # always fetch the current release, so `version` is informational there.
  versionedSources = { apk-pure = true; };
  versionArg = lib.optionalString
    (versionedSources.${normalizedSource} or false) "@${version}";

  # "universal" is a sentinel meaning "download the default variant apkeep
  # serves"; any real Android ABI is passed to apkeep via `-o arch=<abi>`.
  archOption = lib.optionalString (selectedArchStr != "universal")
    "arch=${selectedArchStr}";
  extraOptions = lib.concatStringsSep "," (lib.filter (s: s != "") [ archOption sourceOptions ]);
  sourceArgs = lib.optionalString (extraOptions != "") "-o ${extraOptions}";

  googleArgs = lib.concatStringsSep " " (lib.concatLists [
    (lib.optional (googleEmail != null) "-e ${googleEmail}")
    (lib.optional (googleAasToken != null) "-t ${googleAasToken}")
    (lib.optional (googleAuthToken != null) "--auth-token ${googleAuthToken}")
    (lib.optionals acceptTos [ "--accept-tos" ])
  ]);

  licenseValue =
    if license == "free" then lib.licenses.free
    else if license == "unfree" then lib.licenses.unfree
    else license;
in
assert lib.assertMsg (selectedHash != null) ''
  no hash pinned for system `${system}` on `${pname}` (${
    appId
  }). Add an entry to `archs` / the `hashes.json` sidecar, or pass `hash` when
  the app ships a single universal APK.'';
assert lib.assertMsg (!isFdroid || apkName != null) ''
  f-droid app `${pname}` (${appId}) is missing `apkName`.
  The exact file name inside the repo is required to pin the download; it is
  published by the repo index and stored in hashes.json by scripts/update.py.'';
stdenvNoCC.mkDerivation {
  pname = pname;
  version = version;

  # Fixed-output derivation: Nix re-fetches until the output matches the hash
  # selected above, which is exactly what pins (appId, version, arch, source).
  # Non-F-Droid sources use recursive mode + preserving apkeep's filename so
  # scripts/update.py can hash the identical layout; f-droid uses flat mode
  # because the pinned hash is the APK file's own sha256 from the repo index.
  outputHashAlgo = "sha256";
  outputHash = selectedHash;
  outputHashMode = if isFdroid then "flat" else "recursive";

  nativeBuildInputs = [ apkeep cacert ] ++ lib.optional isFdroid curl;

  dontUnpack = true;
  dontConfigure = true;

  buildPhase = if isFdroid then ''
    runHook preBuild

    # Deterministic fetch: the URL and the expected sha256 both come from the
    # repo's signed index. The FOD check below fails the build on any mismatch.
    mkdir -p download
    curl --fail --location --silent --show-error \
      "${repoUrl}/${apkName}" \
      -o "download/${apkName}"

    runHook postBuild
  '' else ''
    runHook preBuild

    mkdir -p download
    apkeep \
      -a "${appId}${versionArg}" \
      -d "${normalizedSource}" \
      ${sourceArgs} \
      ${googleArgs} \
      download/

    runHook postBuild
  '';

  installPhase = if isFdroid then ''
    runHook preInstall

    # Flat output: the derivation's output IS the APK file.
    install -D -m 0444 "download/${apkName}" "$out"

    runHook postInstall
  '' else ''
    runHook preInstall

    # apkeep emits either a classic `*.apk` or a split `*.xapk` bundle.
    # The filename is preserved so the NAR hash matches what update.py pins.
    mkdir -p $out/share/apk
    for f in download/*; do
      [ -f "$f" ] || continue
      cp "$f" "$out/share/apk/$(basename "$f")"
      break
    done

    runHook postInstall
  '';

  passthru = {
    inherit appId version source normalizedSource;
    arch = selectedArchStr;
    selectedHash = selectedHash;
  };

  meta = with lib; {
    description = "Android APK for ${appId} (${selectedArchStr})";
    homepage = "https://play.google.com/store/apps/details?id=${appId}";
    platforms = platforms.all;
    license = licenseValue;
  } // meta;
}