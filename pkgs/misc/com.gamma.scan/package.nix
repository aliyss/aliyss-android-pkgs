{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "scan";
  appId = "com.gamma.scan";
  version = pin.version;
  archs = pin.architectures;
}
