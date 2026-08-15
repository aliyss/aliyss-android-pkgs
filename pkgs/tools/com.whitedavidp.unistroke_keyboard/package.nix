{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "unistroke_keyboard";
  appId = "com.whitedavidp.unistroke_keyboard";
  source = "f-droid";
  repoUrl = "https://apt.izzysoft.de/fdroid/repo";
  apkName = pin.apkName;
  version = pin.version;
  archs = pin.architectures;
}
