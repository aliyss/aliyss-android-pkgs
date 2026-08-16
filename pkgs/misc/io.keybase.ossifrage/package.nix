{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "ossifrage";
  appId = "io.keybase.ossifrage";
  version = pin.version;
  archs = pin.architectures;
}
