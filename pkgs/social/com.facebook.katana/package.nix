{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "katana";
  appId = "com.facebook.katana";
  version = pin.version;
  archs = pin.architectures;
}
