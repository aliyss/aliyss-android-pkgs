# Sources and the hash model

Where the pins come from, and what each hash actually guarantees. An APK pin is
(a source, a version, a file name, a hash) — this file explains what each of
those is worth and what the trust assumptions are.

## Sources and the hash model

The same Android app can have **different content per provider**, so the
source is pinned in `package.nix` and every hash in `hashes.json` is specific
to that source. `scripts/update.py` always resolves updates against the
provider recorded in the package, never a different one.

| source                  | how hashes are pinned                                            | hash mode     |
|-------------------------|------------------------------------------------------------------|---------------|
| `apk-pure` (default)    | `apkeep` downloads per architecture; NAR hash of the installed `share/apk` layout (computed by `update.py`) | recursive |
| `f-droid`               | **flat file sha256 straight from the repo's signed index** — no download needed to pin | flat |
| IzzyOnDroid (`f-droid` + `repoUrl`) | same as f-droid, against `https://apt.izzysoft.de/fdroid/repo` | flat |
| `github-releases`       | latest release resolved via the GitHub API; the chosen `.apk` asset is downloaded and hashed flat (GitHub publishes no hashes) | flat |
| `google-play` / `aurora`| needs credentials (`GOOGLE_EMAIL` + `GOOGLE_AUTH_TOKEN`/`GOOGLE_AAS_TOKEN`); version cannot be pinned, requires `--rehash` | recursive |

F-Droid-format indexes (`f-droid.org/repo/index-v1.json`, IzzyOnDroid) are
signed and publish, per APK, the exact file name, its sha256 and the signer
certificate fingerprint — so those apps are pinned fully (version + hash +
signer) **without downloading a single APK**, and `fetchApk` downloads
`<repoUrl>/<apkName>` with `outputHashMode = "flat"` so the index hash *is*
the build hash.

`github-releases` apps (open-source apps that APKPure does not carry, e.g.
Orbot, Bitwarden Authenticator, Dantotsu addons) pin the release tag as the
version and the exact asset name in `hashes.json`; `update.py` resolves the
latest release via the GitHub API, downloads the best `.apk` asset
(universal > arm64-v8a > x86_64 > any) and hashes it flat. `package.nix` pins
the `ghRepo` (`owner/repo`) statically.

## Trust model & caveats

* The F-Droid index is served over TLS and additionally signed (JAR/GPG via
  `index-v1.jar` / `index-v1.json.asc`) — verify those for maximum trust.
  Hashes pinned from it are covered by that signature, and `update.py`
  re-verifies downloads with `apksigner` when available.
* IzzyOnDroid hosts many proprietary/freeware apps. `fetchApk` defaults to
  `license = "free"`; review `meta.license` before shipping an Izzy package
  set to unfree-only consumers.
* APKPure/Play apps are frequently unfree; the repo's own package set allows
  them (`config.allowUnfree = true`), consumers importing the overlay keep
  nixpkgs' standard gating.
* Per-ABI-only APKs (e.g. arm64-only) are not seeded by default; universal
  seeds build on any Nix system.
