{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "scaniverse";
  appId = "com.nianticlabs.scaniverse";
  version = pin.version;
  archs = pin.architectures;
}
