{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "kaido";
  appId = "eu.kanade.tachiyomi.animeextension.en.kaido";
  version = pin.version;
  archs = pin.architectures;
}
