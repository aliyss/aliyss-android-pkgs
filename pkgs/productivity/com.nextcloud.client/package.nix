{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "client";
  appId = "com.nextcloud.client";
  version = pin.version;
  archs = pin.architectures;
}
