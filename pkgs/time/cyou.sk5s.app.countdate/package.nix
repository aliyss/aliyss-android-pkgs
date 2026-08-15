{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "countdate";
  appId = "cyou.sk5s.app.countdate";
  source = "f-droid";
  repoUrl = "https://apt.izzysoft.de/fdroid/repo";
  apkName = pin.apkName;
  version = pin.version;
  archs = pin.architectures;
}
