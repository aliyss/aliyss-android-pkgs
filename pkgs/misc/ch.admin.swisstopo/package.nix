{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "swisstopo";
  appId = "ch.admin.swisstopo";
  version = pin.version;
  archs = pin.architectures;
}
