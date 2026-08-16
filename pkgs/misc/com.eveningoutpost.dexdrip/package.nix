{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "dexdrip";
  appId = "com.eveningoutpost.dexdrip";
  version = pin.version;
  archs = pin.architectures;
}
