{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "fdroid";
  appId = "org.fdroid.fdroid";
  version = pin.version;
  archs = pin.architectures;
}
