{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "termux";
  appId = "com.termux";
  version = pin.version;
  archs = pin.architectures;
}
