{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "mobileapp";
  appId = "com.mcdonalds.mobileapp";
  version = pin.version;
  archs = pin.architectures;
}
