{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "translate";
  appId = "com.google.android.apps.translate";
  version = pin.version;
  archs = pin.architectures;
}
