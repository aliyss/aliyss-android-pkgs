{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "citypop";
  appId = "com.citypop.app";
  version = pin.version;
  archs = pin.architectures;
}
