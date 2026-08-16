{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "aniwave";
  appId = "eu.kanade.tachiyomi.animeextension.en.aniwave";
  version = pin.version;
  archs = pin.architectures;
}
