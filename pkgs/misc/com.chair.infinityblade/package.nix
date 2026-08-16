{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "infinityblade";
  appId = "com.chair.infinityblade";
  version = pin.version;
  archs = pin.architectures;
}
