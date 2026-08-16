{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "discord";
  appId = "com.discord";
  version = pin.version;
  archs = pin.architectures;
}
