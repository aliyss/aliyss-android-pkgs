{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "outlook";
  appId = "com.microsoft.office.outlook";
  version = pin.version;
  archs = pin.architectures;
}
