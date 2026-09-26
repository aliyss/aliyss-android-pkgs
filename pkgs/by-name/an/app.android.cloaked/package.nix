{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "cloaked";
  appId = "app.android.cloaked";
  version = pin.version;
  archs = pin.architectures;
}
