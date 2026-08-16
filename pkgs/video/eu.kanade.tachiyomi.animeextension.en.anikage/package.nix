{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "anikage";
  appId = "eu.kanade.tachiyomi.animeextension.en.anikage";
  version = pin.version;
  archs = pin.architectures;
}
