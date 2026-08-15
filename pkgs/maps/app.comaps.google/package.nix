{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "google";
  appId = "app.comaps.google";
  version = pin.version;
  archs = pin.architectures;
}
