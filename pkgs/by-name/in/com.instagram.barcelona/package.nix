{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "barcelona";
  appId = "com.instagram.barcelona";
  version = pin.version;
  archs = pin.architectures;
}
