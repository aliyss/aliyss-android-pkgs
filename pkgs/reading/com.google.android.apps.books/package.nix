{ fetchApk }:

let
  pin = builtins.fromJSON (builtins.readFile ./hashes.json);
in
fetchApk {
  pname = "books";
  appId = "com.google.android.apps.books";
  version = pin.version;
  archs = pin.architectures;
}
