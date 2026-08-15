{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "day";
  appId = "air.com.parkerstech.day";
  version = pin.version;
  archs = pin.architectures;
}
