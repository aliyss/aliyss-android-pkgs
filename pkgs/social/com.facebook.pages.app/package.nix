{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "pages";
  appId = "com.facebook.pages.app";
  version = pin.version;
  archs = pin.architectures;
}
