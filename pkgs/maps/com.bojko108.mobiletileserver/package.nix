{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "mobiletileserver";
  appId = "com.bojko108.mobiletileserver";
  source = "f-droid";
  repoUrl = "https://apt.izzysoft.de/fdroid/repo";
  apkName = pin.apkName;
  version = pin.version;
  archs = pin.architectures;
}
