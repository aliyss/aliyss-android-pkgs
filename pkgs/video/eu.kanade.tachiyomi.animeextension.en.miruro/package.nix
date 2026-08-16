{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "miruro";
  appId = "eu.kanade.tachiyomi.animeextension.en.miruro";
  version = pin.version;
  archs = pin.architectures;
}
