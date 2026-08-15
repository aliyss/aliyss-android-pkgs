{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "force_dark";
  appId = "moe.henry_zhr.force_dark";
  source = "f-droid";
  repoUrl = "https://apt.izzysoft.de/fdroid/repo";
  apkName = pin.apkName;
  version = pin.version;
  archs = pin.architectures;
}
