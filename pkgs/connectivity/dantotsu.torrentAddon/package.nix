{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "dantotsu-torrent-addon";
  appId = "dantotsu.torrentAddon";
  source = "github-releases";
  ghRepo = "rebelonion/Dantotsu-Torrent-Addon";
  version = pin.version;
  apkName = pin.apkName;
  archs = pin.architectures;
}
