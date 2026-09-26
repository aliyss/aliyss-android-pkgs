{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "immich";
  appId = "app.alextran.immich";
  version = pin.version;
  archs = pin.architectures;
}
