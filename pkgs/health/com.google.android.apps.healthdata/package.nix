{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "healthdata";
  appId = "com.google.android.apps.healthdata";
  version = pin.version;
  archs = pin.architectures;
}
