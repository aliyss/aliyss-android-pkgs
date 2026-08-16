{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "allanime";
  appId = "eu.kanade.tachiyomi.animeextension.en.allanime";
  version = pin.version;
  archs = pin.architectures;
}
