# This file describes your repository contents.
# It should return a set of nix derivations
# and optionally the special attributes `lib`, `modules` and `overlays`.
# It should NOT import <nixpkgs>. Instead, you should take pkgs as an argument.
# Having pkgs default to <nixpkgs> is fine though, and it lets you use short
# commands such as:
#     nix-build -A mypackage
{pkgs ? import <nixpkgs> {}}:
let
  jackLib = import ./lib { inherit pkgs; };
  packages = {
    csharpier = pkgs.callPackage ./pkgs/csharpier {};
    docfx = pkgs.callPackage ./pkgs/docfx {};
    epub2tts = pkgs.callPackage ./pkgs/epub2tts {};
    lean = pkgs.callPackage ./pkgs/lean {};
    nbstripout = pkgs.callPackage ./pkgs/nbstripout {};
    roon-server = pkgs.callPackage ./pkgs/roon-server {};
    tod = pkgs.callPackage ./pkgs/tod {};
  };
in
{
  # The `lib`, `modules`, and `overlay` names are special
  lib = jackLib; # functions
  modules = import ./modules; # NixOS modules
  homeManagerModules = import ./home-manager; # Home Manager modules
  overlays = import ./overlays; # nixpkgs overlays
}
// jackLib.filterByPlatforms pkgs.system packages
