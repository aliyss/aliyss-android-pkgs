{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "moapp";
  appId = "ch.stadt.sg.moapp";
  version = pin.version;
  archs = pin.architectures;
}
