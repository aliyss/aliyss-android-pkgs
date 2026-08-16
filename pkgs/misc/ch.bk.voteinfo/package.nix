{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "voteinfo";
  appId = "ch.bk.voteinfo";
  version = pin.version;
  archs = pin.architectures;
}
