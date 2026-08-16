{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "github";
  appId = "com.github.android";
  version = pin.version;
  archs = pin.architectures;
}
