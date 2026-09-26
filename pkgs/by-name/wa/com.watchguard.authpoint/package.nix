{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "authpoint";
  appId = "com.watchguard.authpoint";
  version = pin.version;
  archs = pin.architectures;
}
