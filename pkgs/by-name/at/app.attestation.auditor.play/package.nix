{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "auditor";
  appId = "app.attestation.auditor.play";
  version = pin.version;
  archs = pin.architectures;
}
