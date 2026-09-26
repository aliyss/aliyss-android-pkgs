{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "one";
  appId = "com.stremio.one";
  version = pin.version;
  archs = pin.architectures;
}
