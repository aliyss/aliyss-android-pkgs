{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "spotify";
  appId = "com.spotify.music";
  version = pin.version;
  archs = pin.architectures;
  license = "unfree";
}
