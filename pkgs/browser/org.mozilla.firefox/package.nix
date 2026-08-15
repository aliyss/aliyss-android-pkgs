{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "firefox";
  appId = "org.mozilla.firefox";
  version = pin.version;
  archs = pin.architectures;
}
