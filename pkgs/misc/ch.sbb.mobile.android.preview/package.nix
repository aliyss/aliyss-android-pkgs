{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "preview";
  appId = "ch.sbb.mobile.android.preview";
  version = pin.version;
  archs = pin.architectures;
}
