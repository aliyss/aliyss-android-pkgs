{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "deglaze";
  appId = "app.deglaze.prod";
  version = pin.version;
  archs = pin.architectures;
}
