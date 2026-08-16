{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "linkedin";
  appId = "com.linkedin.android";
  version = pin.version;
  archs = pin.architectures;
}
