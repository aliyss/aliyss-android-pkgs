{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "accrescent";
  appId = "app.accrescent.client";
  version = pin.version;
  archs = pin.architectures;
}
