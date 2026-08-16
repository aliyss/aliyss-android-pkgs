{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "flutter";
  appId = "app.revanced.manager.flutter";
  version = pin.version;
  archs = pin.architectures;
}
