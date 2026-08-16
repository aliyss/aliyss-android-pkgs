{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "community";
  appId = "com.valvesoftware.android.steam.community";
  version = pin.version;
  archs = pin.architectures;
}
