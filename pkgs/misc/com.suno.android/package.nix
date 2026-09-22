{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "suno";
  appId = "com.suno.android";
  version = pin.version;
  archs = pin.architectures;
}
