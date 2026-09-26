{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "rider";
  appId = "app.avas.rider";
  version = pin.version;
  archs = pin.architectures;
}
