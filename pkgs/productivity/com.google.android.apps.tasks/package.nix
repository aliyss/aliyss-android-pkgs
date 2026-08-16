{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "tasks";
  appId = "com.google.android.apps.tasks";
  version = pin.version;
  archs = pin.architectures;
}
