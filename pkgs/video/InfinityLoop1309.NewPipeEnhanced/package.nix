{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "NewPipeEnhanced";
  appId = "InfinityLoop1309.NewPipeEnhanced";
  version = pin.version;
  archs = pin.architectures;
}
