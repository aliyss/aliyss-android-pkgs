{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "stickermakerforwhatsapp";
  appId = "com.marsvard.stickermakerforwhatsapp";
  version = pin.version;
  archs = pin.architectures;
}
