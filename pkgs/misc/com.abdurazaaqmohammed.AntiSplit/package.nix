{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "AntiSplit";
  appId = "com.abdurazaaqmohammed.AntiSplit";
  version = pin.version;
  archs = pin.architectures;
}
