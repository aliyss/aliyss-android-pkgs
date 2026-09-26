{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "telegram";
  appId = "org.telegram.messenger";
  version = pin.version;
  archs = pin.architectures;
}
