{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "TotalCommander";
  appId = "com.ghisler.android.TotalCommander";
  version = pin.version;
  archs = pin.architectures;
}
