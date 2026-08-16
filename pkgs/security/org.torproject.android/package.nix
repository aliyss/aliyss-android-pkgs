{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "orbot";
  appId = "org.torproject.android";
  source = "github-releases";
  ghRepo = "guardianproject/orbot";
  version = pin.version;
  apkName = pin.apkName;
  archs = pin.architectures;
}
