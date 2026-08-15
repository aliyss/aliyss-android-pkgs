{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "vlc";
  appId = "org.videolan.vlc";
  version = pin.version;
  archs = pin.architectures;
}
