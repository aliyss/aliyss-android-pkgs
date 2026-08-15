{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "comaps";
  appId = "app.comaps";
  version = pin.version;
  archs = pin.architectures;
}
