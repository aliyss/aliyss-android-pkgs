{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "linear";
  appId = "app.linear";
  version = pin.version;
  archs = pin.architectures;
}
