{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "remarkable";
  appId = "com.remarkable.mobile";
  version = pin.version;
  archs = pin.architectures;
}
