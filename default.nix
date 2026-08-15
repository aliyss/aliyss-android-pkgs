# Legacy (non-flake) entrypoint.
#
#   nix-build -A com-spotify-music
#
{ pkgs ? import <nixpkgs> { } }:

import ./pkgs { inherit pkgs; }
