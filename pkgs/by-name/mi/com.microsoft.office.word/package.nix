{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "word";
  appId = "com.microsoft.office.word";
  version = pin.version;
  archs = pin.architectures;
}
