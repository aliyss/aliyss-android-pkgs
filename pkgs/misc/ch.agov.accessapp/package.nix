{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "accessapp";
  appId = "ch.agov.accessapp";
  version = pin.version;
  archs = pin.architectures;
}
