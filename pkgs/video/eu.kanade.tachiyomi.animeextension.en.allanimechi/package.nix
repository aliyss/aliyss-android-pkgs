{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "allanimechi";
  appId = "eu.kanade.tachiyomi.animeextension.en.allanimechi";
  version = pin.version;
  archs = pin.architectures;
}
