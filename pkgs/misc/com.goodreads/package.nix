{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "goodreads";
  appId = "com.goodreads";
  version = pin.version;
  archs = pin.architectures;
}
