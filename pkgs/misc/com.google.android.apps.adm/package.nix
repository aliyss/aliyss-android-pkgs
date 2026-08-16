{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "adm";
  appId = "com.google.android.apps.adm";
  version = pin.version;
  archs = pin.architectures;
}
