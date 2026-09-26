{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "walletnfcrel";
  appId = "com.google.android.apps.walletnfcrel";
  version = pin.version;
  archs = pin.architectures;
}
