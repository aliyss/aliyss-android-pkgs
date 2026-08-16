{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "revolut";
  appId = "com.revolut.revolut";
  version = pin.version;
  archs = pin.architectures;
}
