{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "lemmy";
  appId = "com.rubenmayayo.lemmy";
  version = pin.version;
  archs = pin.architectures;
}
