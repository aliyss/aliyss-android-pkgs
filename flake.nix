{
  description = "Repository for Android applications (APKPure / Play Store apps)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self
    , nixpkgs
    ,
    }:
    let
      # x86_64-darwin was dropped by nixpkgs 26.11; APK fetching itself uses
      # only apkeep, but keeping the list in sync with nixpkgs keeps eval clean.
      systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      packageSetFor = system:
        let
          # APKPure / Play Store apps are frequently unfree; the repository's
          # own package set allows them (consumers importing the overlay keep
          # nixpkgs' standard allowUnfree gating on their side).
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
          };
        in
        import ./pkgs { inherit pkgs; };

      # The installer (scripts/install.sh) as a runnable package: builds a
      # package from a flake and installs/uninstalls it on a device — via adb
      # from a desktop, or directly on the device itself (Termux, no adb) with
      # `su -c 'pm install'`. This is the single install entry point; consumers
      # (e.g. the dotfiles' aliyss.androidPkgs home-manager module and the
      # phone's install-app command) call it instead of shipping their own.
      android-install = system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        pkgs.writeShellApplication {
          name = "android-install";
          runtimeInputs = with pkgs; [
            bash
            coreutils
            findutils
            gawk
            gnugrep
          ];
          text = builtins.readFile ./scripts/install.sh;
        };

      # The enforcer (scripts/enforce.sh) as a runnable package: applies the
      # declared runtime permissions + notification access for the managed apps
      # with root (adb, or on-device directly). install.sh puts the APK there,
      # this makes it behave the way the config says.
      android-enforce = system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        pkgs.writeShellApplication {
          name = "android-enforce";
          runtimeInputs = with pkgs; [
            bash
            coreutils
            gawk
            gnugrep
            gnused
            jq
          ];
          text = builtins.readFile ./scripts/enforce.sh;
        };

      # Python with everything the scripts and the offline test suite need.
      # (ruff runs the lint/format checks, mypy the type checks; keep in sync
      # with pyproject.toml.)
      # The curated per-app baselines, bundled into one index for
      # android-enforce --recommended (see lib/recommended.nix).
      android-recommended = system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        pkgs.callPackage ./lib/recommended.nix { };

      testPython = system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        pkgs.python3.withPackages (ps:
          with ps; [
            pytest
            httpx
            beautifulsoup4
            lxml
            pyyaml
            mypy
            types-pyyaml
            ruff
          ]);
    in
    {
      # Packages generated per system architecture, e.g.
      #   nix build .#com-spotify-music
      # plus the shared installer:
      #   nix build .#android-install
      packages = forAllSystems (system:
        packageSetFor system
        // {
          android-install = android-install system;
          android-enforce = android-enforce system;
          android-recommended = android-recommended system;
        });

      # legacyPackages lets the whole set be used from within a nixpkgs-based
      # context and satisfies the flake requirements.
      legacyPackages = forAllSystems (system:
        packageSetFor system
        // {
          android-install = android-install system;
          android-enforce = android-enforce system;
          android-recommended = android-recommended system;
        });

      # Reusable fetcher for consumers who want to build ad-hoc APKs.
      lib.fetchApk = nixpkgs.legacyPackages.x86_64-linux.callPackage ./lib/fetchApk.nix { };

      # Home-manager module for declarative Android app installs.
      # Import via `aliyss-android-pkgs.homeManagerModules.<system>.default`
      # (with enable = true) and set `aliyss.androidPkgs.apps = { "<app-id>" = { ... }; };`.
      homeManagerModules = forAllSystems (system: {
        default = import ./home-manager-module.nix;
      });

      # Offline test suite: unit tests for the scripts plus structural
      # invariants over the whole pkgs/ tree (see ./tests).
      checks = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          tests =
            pkgs.runCommand "android-apps-tests"
              {
                nativeBuildInputs = [ (testPython system) ];
              } ''
              cp -r ${./scripts} scripts
              cp -r ${./tests} tests
              cp -r ${./pkgs} pkgs
              cp ${./pyproject.toml} pyproject.toml
              # Lint + format + type gate, then the offline test suite.
              ruff check scripts/ tests/
              ruff format --check scripts/ tests/
              mypy scripts/ tests/
              pytest -q tests/
              touch $out
            '';
          # shellcheck + parse check over the two device-facing scripts. These
          # are the only files that run as root on a phone, so they get the same
          # gate the Python gets from ruff/mypy.
          shell =
            pkgs.runCommand "android-pkgs-shell"
              {
                nativeBuildInputs = [ pkgs.shellcheck pkgs.bash ];
              } ''
              cp -r ${./scripts} scripts
              cp -r ${./tests} tests
              shellcheck --severity=warning -s bash scripts/*.sh tests/*.sh tests/fake/*
              for f in scripts/*.sh tests/*.sh tests/fake/*; do
                bash -n "$f"
              done
              touch $out
            '';

          # The config shapes android-enforce accepts (the canonical per-app
          # layout and the older flat one) plus the curated-baseline merge. No
          # device and no root: --print-effective only folds the config.
          enforce-config =
            pkgs.runCommand "android-enforce-config-test"
              {
                nativeBuildInputs = [ pkgs.bash pkgs.jq ];
                ENFORCE = "${android-enforce system}/bin/android-enforce";
              } ''
              cp -r ${./tests} tests
              bash tests/enforce_config_test.sh
              touch $out
            '';

          # The enforce walk off the device: the root scripts android-enforce
          # generates are run under a fake su, and fake dumpsys/appops/pm/
          # settings answer from fixtures, so the walk's decisions (the managed
          # posture, the drift report, the listener state) are exercised with no
          # device and no root.
          enforce-walk =
            pkgs.runCommand "android-enforce-walk-test"
              {
                nativeBuildInputs = with pkgs; [ bash coreutils gnugrep gnused jq ];
                ENFORCE = "${android-enforce system}/bin/android-enforce";
              } ''
              cp -r ${./tests} tests
              bash tests/enforce_walk_test.sh
              touch $out
            '';
        });

      devShells = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              apkeep
              nixpkgs-fmt
              ruff
              mypy
              shellcheck
              python3
              (python3.withPackages (ps: with ps; [ httpx beautifulsoup4 lxml pyyaml pytest types-pyyaml ]))
            ];
          };
        });

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt);
    };
}
