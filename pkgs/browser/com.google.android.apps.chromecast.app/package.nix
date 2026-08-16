{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "chromecast";
  appId = "com.google.android.apps.chromecast.app";
  version = pin.version;
  archs = pin.architectures;
}
