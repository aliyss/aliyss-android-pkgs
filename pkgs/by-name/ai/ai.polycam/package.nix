{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "polycam";
  appId = "ai.polycam";
  version = pin.version;
  archs = pin.architectures;
}
