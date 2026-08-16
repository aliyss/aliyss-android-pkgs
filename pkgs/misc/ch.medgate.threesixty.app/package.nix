{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "threesixty";
  appId = "ch.medgate.threesixty.app";
  version = pin.version;
  archs = pin.architectures;
}
