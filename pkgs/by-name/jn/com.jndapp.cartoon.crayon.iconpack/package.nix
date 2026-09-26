{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "iconpack";
  appId = "com.jndapp.cartoon.crayon.iconpack";
  version = pin.version;
  archs = pin.architectures;
}
