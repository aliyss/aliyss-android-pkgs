{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "nfcreader";
  appId = "com.ssaurel.nfcreader";
  version = pin.version;
  archs = pin.architectures;
}
