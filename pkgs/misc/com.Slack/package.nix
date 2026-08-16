{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "Slack";
  appId = "com.Slack";
  version = pin.version;
  archs = pin.architectures;
}
