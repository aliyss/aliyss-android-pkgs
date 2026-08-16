{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "lens";
  appId = "com.google.ar.lens";
  version = pin.version;
  archs = pin.architectures;
}
