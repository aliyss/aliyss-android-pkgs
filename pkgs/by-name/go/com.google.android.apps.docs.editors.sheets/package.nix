{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "sheets";
  appId = "com.google.android.apps.docs.editors.sheets";
  version = pin.version;
  archs = pin.architectures;
}
