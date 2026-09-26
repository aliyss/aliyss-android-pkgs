{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "migros";
  appId = "ch.migros.app";
  version = pin.version;
  archs = pin.architectures;
}
