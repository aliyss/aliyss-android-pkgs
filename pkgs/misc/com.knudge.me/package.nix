{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "me";
  appId = "com.knudge.me";
  version = pin.version;
  archs = pin.architectures;
}
