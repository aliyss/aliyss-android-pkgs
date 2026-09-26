{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "sleep";
  appId = "com.urbandroid.sleep";
  version = pin.version;
  archs = pin.architectures;
}
