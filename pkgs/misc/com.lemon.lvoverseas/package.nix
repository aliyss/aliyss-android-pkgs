{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "lvoverseas";
  appId = "com.lemon.lvoverseas";
  version = pin.version;
  archs = pin.architectures;
}
