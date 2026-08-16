{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "whatsapp";
  appId = "com.whatsapp";
  version = pin.version;
  archs = pin.architectures;
}
