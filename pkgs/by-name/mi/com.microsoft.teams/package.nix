{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "teams";
  appId = "com.microsoft.teams";
  version = pin.version;
  archs = pin.architectures;
}
