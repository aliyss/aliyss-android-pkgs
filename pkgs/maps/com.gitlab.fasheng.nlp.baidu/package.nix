{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "baidu";
  appId = "com.gitlab.fasheng.nlp.baidu";
  source = "f-droid";
  repoUrl = "https://apt.izzysoft.de/fdroid/repo";
  apkName = pin.apkName;
  version = pin.version;
  archs = pin.architectures;
}
