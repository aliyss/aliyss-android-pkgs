{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "signal";
  appId = "org.thoughtcrime.securesms";
  version = pin.version;
  archs = pin.architectures;
}
