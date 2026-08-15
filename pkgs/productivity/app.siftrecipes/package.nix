{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "siftrecipes";
  appId = "app.siftrecipes";
  source = "f-droid";
  repoUrl = "https://f-droid.org/repo";
  apkName = pin.apkName;
  version = pin.version;
  archs = pin.architectures;
}
