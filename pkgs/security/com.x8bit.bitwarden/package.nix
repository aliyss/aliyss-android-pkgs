{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "bitwarden";
  appId = "com.x8bit.bitwarden";
  version = pin.version;
  archs = pin.architectures;
}
