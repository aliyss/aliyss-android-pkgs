{
  description = "Repository for Android applications (APKPure / Play Store apps)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = {
    self,
    nixpkgs,
  }: let
    # x86_64-darwin was dropped by nixpkgs 26.11; APK fetching itself uses
    # only apkeep, but keeping the list in sync with nixpkgs keeps eval clean.
    systems = ["x86_64-linux" "aarch64-linux" "aarch64-darwin"];
    forAllSystems = nixpkgs.lib.genAttrs systems;

    packageSetFor = system: let
      # APKPure / Play Store apps are frequently unfree; the repository's
      # own package set allows them (consumers importing the overlay keep
      # nixpkgs' standard allowUnfree gating on their side).
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };
    in
      import ./pkgs {inherit pkgs;};

    # Python with everything the scripts and the offline test suite need.
    testPython = system: let
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
  in {
    # Packages generated per system architecture, e.g.
    #   nix build .#com-spotify-music
    packages = forAllSystems packageSetFor;

    # legacyPackages lets the whole set be used from within a nixpkgs-based
    # context and satisfies the flake requirements.
    legacyPackages = forAllSystems packageSetFor;

    # Reusable fetcher for consumers who want to build ad-hoc APKs.
    lib.fetchApk = nixpkgs.legacyPackages.x86_64-linux.callPackage ./lib/fetchApk.nix {};

    # Offline test suite: unit tests for the scripts plus structural
    # invariants over the whole pkgs/ tree (see ./tests).
    checks = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      tests =
        pkgs.runCommand "android-apps-tests" {
          nativeBuildInputs = [(testPython system)];
        } ''
          cp -r ${./scripts} scripts
          cp -r ${./tests} tests
          cp -r ${./pkgs} pkgs
          pytest -q tests/
          touch $out
        '';
    });

    devShells = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.mkShell {
        packages = with pkgs; [
          apkeep
          nixpkgs-fmt
          python3
          (python3.withPackages (ps: with ps; [httpx beautifulsoup4 lxml pyyaml pytest]))
        ];
      };
    });

    formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt);
  };
}
