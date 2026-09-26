{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "aawireless";
  appId = "app.aawireless";
  version = pin.version;
  archs = pin.architectures;
}
