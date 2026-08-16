{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "bitwarden-authenticator";
  appId = "com.bitwarden.authenticator";
  source = "github-releases";
  ghRepo = "bitwarden/authenticator-android";
  version = pin.version;
  apkName = pin.apkName;
  archs = pin.architectures;
}
