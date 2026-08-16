{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "snapseed";
  appId = "com.niksoftware.snapseed";
  version = pin.version;
  archs = pin.architectures;
}
