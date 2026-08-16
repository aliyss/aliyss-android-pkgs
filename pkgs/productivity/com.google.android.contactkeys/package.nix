{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "contactkeys";
  appId = "com.google.android.contactkeys";
  version = pin.version;
  archs = pin.architectures;
}
