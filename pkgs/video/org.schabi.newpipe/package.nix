{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "newpipe";
  appId = "org.schabi.newpipe";
  version = pin.version;
  archs = pin.architectures;
}
