{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "magazines";
  appId = "com.google.android.apps.magazines";
  version = pin.version;
  archs = pin.architectures;
}
