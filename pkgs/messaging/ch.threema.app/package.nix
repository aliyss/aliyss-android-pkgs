{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "threema";
  appId = "ch.threema.app";
  version = pin.version;
  archs = pin.architectures;
}
