{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "Paymit";
  appId = "com.ubs.Paymit.android";
  version = pin.version;
  archs = pin.architectures;
}
