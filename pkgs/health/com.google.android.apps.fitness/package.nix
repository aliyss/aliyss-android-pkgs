{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "fitness";
  appId = "com.google.android.apps.fitness";
  version = pin.version;
  archs = pin.architectures;
}
