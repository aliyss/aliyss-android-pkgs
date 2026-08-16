{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "creator";
  appId = "com.google.android.apps.youtube.creator";
  version = pin.version;
  archs = pin.architectures;
}
