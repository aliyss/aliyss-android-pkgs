{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "excel";
  appId = "com.microsoft.office.excel";
  version = pin.version;
  archs = pin.architectures;
}
