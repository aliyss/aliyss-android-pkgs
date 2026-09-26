{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "wzsabre";
  appId = "app.sabre.wzsabre";
  version = pin.version;
  archs = pin.architectures;
}
