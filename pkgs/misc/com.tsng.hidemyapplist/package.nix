{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "hidemyapplist";
  appId = "com.tsng.hidemyapplist";
  version = pin.version;
  archs = pin.architectures;
}
