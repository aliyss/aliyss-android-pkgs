# Updating

`scripts/update.py` moves an app from its pinned version to the current one and
rewrites the pin. Every source is updated from published metadata (a signed
index, the GitHub API) rather than by downloading and guessing, which is what
makes the automated run below safe to review.

## Updating

```console
python scripts/update.py                 # update everything (writes)
python scripts/update.py --check         # only report
python scripts/update.py --only org.thoughtcrime.securesms
python scripts/update.py --rehash        # recompute hashes for pinned versions
python scripts/update.py --history       # fetch per-app version history (history.json)
python scripts/update.py --history --check   # report history changes without writing
```

* apk-pure apps: queries `apkeep -l`, downloads per architecture, hashes and
  rewrites `hashes.json`.
* f-droid / Izzy apps: reads the repo's index (fetched once per repo) and
  pins the new version + flat hash directly — no download.
* github-releases apps: resolves the latest release via the GitHub API and
  pins the best `.apk` asset (version = release tag).
* google-play / aurora apps: skipped unless `--rehash` (credentials via env).

When a downloaded APK's signer does not match `verified.json` (checked with
`apksigner` when available), the update fails. APKPure seeds start with an
empty fingerprint list (APKPure publishes no signing-certificate database);
the first download verified with `apksigner` records the observed
fingerprints into `verified.json`, after which every update re-checks against
them.

## Version history

Every app can carry a `history.json` with its version history, newest first:

```console
python scripts/update.py --history          # all apps
python scripts/update.py --history --only com.Slack
```

* apk-pure apps: fetched from the APKPure `/versions` page (versionCode, date,
  size) and merged with `apkeep -l` (the full list of versions apkeep can
  actually download); apps whose web page is geo-blocked still get the apkeep
  list.
* f-droid / Izzy apps: derived from the repo's signed index (every APK entry),
  so it is complete and free.
* github-releases apps: derived from the GitHub releases API (release tag,
  date, asset size).

Apps with no public source (closed-source apps absent from APKPure, e.g.
Discord, which APKPure lists under a non-numeric "Stable" version) simply keep
an empty history.

The schema is validated by the test suite (`tests/test_repo_structure.py`).

## The automated run

`.github/workflows/update.yml` runs nightly (04:17 UTC) and on demand, and
**opens a PR** rather than pushing to master:

```console
nix develop -c python scripts/update.py \
  --systems x86_64-linux=universal,aarch64-linux=universal,aarch64-darwin=universal
nix develop -c python scripts/update.py --history
```

It needs no credentials and no device, because the sources this repo actually
uses publish what a pin needs: an f-droid pin is the signed index's own
`apkName` and sha256, and a github-releases pin is the hash of a named release
asset. (An apk-pure pin does come from a downloaded APK, which is verified
against `verified.json` — that is the source whose first download has nothing to
compare against, so review those bumps a little harder.) The PR is what puts CI
— which re-evaluates every package and re-runs the structural tests — between
the bump and master. If nothing changed, no PR is opened.

The `--systems` list is explicit so a newly pinned app is buildable on every
system the flake targets, not just the runner's: the same universal APK serves
all three, and the hash is stamped onto each. Specs may be comma-separated or
spread over separate arguments.

Running it by hand is the same command. apk-pure apps need `apkeep` and `nix`
on `PATH` (the devShell provides both); f-droid and github-releases apps need
neither.

