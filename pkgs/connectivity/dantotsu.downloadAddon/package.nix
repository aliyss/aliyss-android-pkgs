{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "dantotsu-download-addon";
  appId = "dantotsu.downloadAddon";
  source = "github-releases";
  ghRepo = "rebelonion/Dantotsu-Download-Addon";
  version = pin.version;
  apkName = pin.apkName;
  archs = pin.architectures;
}
