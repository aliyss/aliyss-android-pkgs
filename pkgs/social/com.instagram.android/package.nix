{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "instagram";
  appId = "com.instagram.android";
  version = pin.version;
  archs = pin.architectures;
}
