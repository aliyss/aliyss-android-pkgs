{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "cashyou";
  appId = "com.cashyou";
  version = pin.version;
  archs = pin.architectures;
}
