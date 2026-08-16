{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "glucodata";
  appId = "tk.glucodata";
  version = pin.version;
  archs = pin.architectures;
}
