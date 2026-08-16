{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "anilist";
  appId = "eu.kanade.tachiyomi.animeextension.en.anilist";
  version = pin.version;
  archs = pin.architectures;
}
