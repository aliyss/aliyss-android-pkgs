{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "wohnungssuche_app";
  appId = "ch.wohnungssuche.wohnungssuche_app";
  version = pin.version;
  archs = pin.architectures;
}
