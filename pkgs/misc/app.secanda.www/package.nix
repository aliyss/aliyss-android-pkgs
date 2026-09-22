{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "www";
  appId = "app.secanda.www";
  version = pin.version;
  archs = pin.architectures;
}
