{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "wdnfc";
  appId = "com.wakdev.wdnfc";
  version = pin.version;
  archs = pin.architectures;
}
