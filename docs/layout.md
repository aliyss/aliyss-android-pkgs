# Repo layout

The app tree is organised by name, so an app's path follows from its app id and
nothing has to be listed anywhere. This is the convention every script, the
flake walkers and the tests agree on.

Apps live under `pkgs/by-name/<shard>/<app-id>/`, like nixpkgs' `pkgs/by-name`:
the app id is the directory name and the shard is computed from that name
alone, so seeding an app is one `mkdir` and nothing has to be listed anywhere.

```console
pkgs/by-name/sp/com.spotify.music/{package.nix,hashes.json,verified.json}
pkgs/by-name/th/org.thoughtcrime.securesms/...
```

The shard is the first two characters of the app's **publisher label** — the
label after the TLD: `com.spotify.music` -> `sp`, `org.thoughtcrime.securesms`
-> `th`. Android ids are reverse-DNS, so sharding on the whole id (nixpkgs'
rule) would put every `com.*` id in one `co/` directory: 1881 of the 4199 apps.
Sharding on the publisher label spreads them over 466 directories, the largest
holding 285. A two-label id uses its first label (`a2dp.Vol` -> `a2`), and a
label shorter than two characters falls back to the id (`S.N.A.K.E` -> `sn`).

The rule lives in exactly one place — `scripts/layout.py`, mirrored in
`pkgs/default.nix` — and `tests/test_layout.py` pins it, with the structural
tests asserting that every app directory sits in its own shard. To add an app
by hand, mkdir the two directories and write `package.nix` + `hashes.json`;
`nix build .#<app-id-with-dashes>` picks it up immediately.

