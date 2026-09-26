{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "SplitwiseMobile";
  appId = "com.Splitwise.SplitwiseMobile";
  version = pin.version;
  archs = pin.architectures;
}
