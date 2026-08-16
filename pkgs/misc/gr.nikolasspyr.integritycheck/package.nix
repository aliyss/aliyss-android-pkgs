{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "integritycheck";
  appId = "gr.nikolasspyr.integritycheck";
  version = pin.version;
  archs = pin.architectures;
}
