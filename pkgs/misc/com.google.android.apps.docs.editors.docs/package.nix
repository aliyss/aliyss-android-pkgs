{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "docs";
  appId = "com.google.android.apps.docs.editors.docs";
  version = pin.version;
  archs = pin.architectures;
}
