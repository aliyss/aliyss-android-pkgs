{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "sukisu-ultra";
  appId = "com.sukisu.ultra";
  source = "github-releases";
  ghRepo = "SukiSU-Ultra/SukiSU-Ultra";
  version = pin.version;
  apkName = pin.apkName;
  archs = pin.architectures;
}
