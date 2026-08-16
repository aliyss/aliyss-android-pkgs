{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "animepahe";
  appId = "eu.kanade.tachiyomi.animeextension.en.animepahe";
  version = pin.version;
  archs = pin.architectures;
}
