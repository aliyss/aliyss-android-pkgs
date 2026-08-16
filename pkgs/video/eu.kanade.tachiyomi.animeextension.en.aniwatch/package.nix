{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "aniwatch";
  appId = "eu.kanade.tachiyomi.animeextension.en.aniwatch";
  version = pin.version;
  archs = pin.architectures;
}
