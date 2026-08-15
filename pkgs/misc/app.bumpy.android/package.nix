{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "bumpy";
  appId = "app.bumpy.android";
  version = pin.version;
  archs = pin.architectures;
}
