{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "verifier";
  appId = "com.google.android.verifier";
  version = pin.version;
  archs = pin.architectures;
}
