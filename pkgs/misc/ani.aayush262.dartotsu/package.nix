{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "dartotsu";
  appId = "ani.aayush262.dartotsu";
  source = "github-releases";
  ghRepo = "aayush2622/Dartotsu";
  version = pin.version;
  apkName = pin.apkName;
  archs = pin.architectures;
}
