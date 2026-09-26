{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "agrisano";
  appId = "ch.agrisano.agrisano";
  version = pin.version;
  archs = pin.architectures;
}
