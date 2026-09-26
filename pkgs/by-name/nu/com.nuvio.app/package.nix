{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "nuvio";
  appId = "com.nuvio.app";
  version = pin.version;
  archs = pin.architectures;
}
