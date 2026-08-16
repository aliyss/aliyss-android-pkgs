{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "snapchat";
  appId = "com.snapchat.android";
  version = pin.version;
  archs = pin.architectures;
}
