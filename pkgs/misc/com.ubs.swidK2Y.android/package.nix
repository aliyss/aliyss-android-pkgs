{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "swidK2Y";
  appId = "com.ubs.swidK2Y.android";
  version = pin.version;
  archs = pin.architectures;
}
