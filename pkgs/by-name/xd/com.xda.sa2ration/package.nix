{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "sa2ration";
  appId = "com.xda.sa2ration";
  version = pin.version;
  archs = pin.architectures;
}
