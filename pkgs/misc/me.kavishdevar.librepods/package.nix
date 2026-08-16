{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "librepods";
  appId = "me.kavishdevar.librepods";
  version = pin.version;
  archs = pin.architectures;
}
