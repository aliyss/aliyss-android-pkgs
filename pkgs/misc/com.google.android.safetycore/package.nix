{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "safetycore";
  appId = "com.google.android.safetycore";
  version = pin.version;
  archs = pin.architectures;
}
