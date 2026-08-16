{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "animenosub";
  appId = "eu.kanade.tachiyomi.animeextension.en.animenosub";
  version = pin.version;
  archs = pin.architectures;
}
