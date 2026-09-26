{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "tgtg";
  appId = "com.app.tgtg";
  version = pin.version;
  archs = pin.architectures;
}
