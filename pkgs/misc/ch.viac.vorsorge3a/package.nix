{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "vorsorge3a";
  appId = "ch.viac.vorsorge3a";
  version = pin.version;
  archs = pin.architectures;
}
