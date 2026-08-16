{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "sleepIfUCan";
  appId = "droom.sleepIfUCan";
  version = pin.version;
  archs = pin.architectures;
}
