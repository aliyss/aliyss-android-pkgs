{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "komoot";
  appId = "de.komoot.android";
  version = pin.version;
  archs = pin.architectures;
}
