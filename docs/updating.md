# Updating

`scripts/update.py` moves an app from its pinned version to the current one and
rewrites the pin. Every source is updated from published metadata (a signed
index, the GitHub API) rather than by downloading and guessing, which is what
makes the daily automated run in `.github/workflows/update.yml` safe to review.

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

