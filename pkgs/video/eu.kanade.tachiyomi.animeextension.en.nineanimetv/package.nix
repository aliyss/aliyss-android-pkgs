{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "nineanimetv";
  appId = "eu.kanade.tachiyomi.animeextension.en.nineanimetv";
  version = pin.version;
  archs = pin.architectures;
}
