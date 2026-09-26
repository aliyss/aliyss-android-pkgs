{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "privatelm";
  appId = "com.orailnoor.privatelm";
  source = "github-releases";
  ghRepo = "orailnoor/cross-platform-llm-client";
  version = pin.version;
  apkName = pin.apkName;
  archs = pin.architectures;
}
