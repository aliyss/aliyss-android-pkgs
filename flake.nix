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

      # Python with everything the scripts and the offline test suite need.
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
          ]);
    in
    {
      # Packages generated per system architecture, e.g.
      #   nix build .#com-spotify-music
      # plus the shared installer:
      #   nix build .#android-install
      packages = forAllSystems (system:
        packageSetFor system // { android-install = android-install system; });

      # legacyPackages lets the whole set be used from within a nixpkgs-based
      # context and satisfies the flake requirements.
      legacyPackages = forAllSystems (system:
        packageSetFor system // { android-install = android-install system; });

      # Reusable fetcher for consumers who want to build ad-hoc APKs.
      lib.fetchApk = nixpkgs.legacyPackages.x86_64-linux.callPackage ./lib/fetchApk.nix { };

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
              pytest -q tests/
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
              python3
              (python3.withPackages (ps: with ps; [ httpx beautifulsoup4 lxml pyyaml pytest ]))
            ];
          };
        });

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt);
    };
}
