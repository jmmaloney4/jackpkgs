# You can use this file as a nixpkgs overlay. This is useful in the
# case where you don't want to add the whole NUR namespace to your
# configuration.
#
# When used from the flake, bun2nix inputs are passed as the first argument.
inputs: self: super:
if !(super ? callPackage && super ? system)
then {}
else let
  # When used standalone (without flake inputs), fetch bun2nix from GitHub.
  bun2nixOverlay =
    if inputs ? bun2nix
    then inputs.bun2nix.overlays.default
    else
      (import (builtins.fetchTarball {
        url = "https://github.com/nix-community/bun2nix/archive/f2bc12af1a6369648aac41041ceeaa0b866599c6.tar.gz";
        sha256 = "sha256-oQvcadh2BCkrog+SGrG6YffKJrveYpjj3TdQJWaKhaM=";
      })).overlays.default;
  isReserved = n: n == "lib" || n == "overlays" || n == "modules";
  nameValuePair = n: v: {
    name = n;
    value = v;
  };
  nvfetcherSources = super.callPackage ./_sources/generated.nix {};
  superWithBun2nix = super // (bun2nixOverlay self super);
  # Define packages inline instead of importing default.nix
  allPackages = {
    csharpier = super.callPackage ./pkgs/csharpier {};
    codex-proxy = super.callPackage ./pkgs/codex-proxy {
      inherit (nvfetcherSources.codex-proxy) src version;
    };
    codex-proxy-rs = super.callPackage ./pkgs/codex-proxy-rs {
      inherit (nvfetcherSources.codex-proxy-rs) src version;
    };
    docfx = super.callPackage ./pkgs/docfx {};
    gemini-proxy = superWithBun2nix.callPackage ./pkgs/gemini-proxy {
      inherit (nvfetcherSources.gemini-proxy) src version;
    };
    epub2tts = super.callPackage ./pkgs/epub2tts {};
    imessage-bridge = super.callPackage ./pkgs/imessage-bridge {};
    lean = super.callPackage ./pkgs/lean {};
    mcp-ynab = super.callPackage ./pkgs/mcp-ynab {
      inherit (nvfetcherSources.mcp-ynab) src version;
    };
    pulumi-drift-report = super.callPackage ./pkgs/pulumi-drift-report {};
    seedtool-cli = super.callPackage ./pkgs/seedtool-cli {};
    spooktacular = super.callPackage ./pkgs/spooktacular {
      inherit (nvfetcherSources.spooktacular) src date;
    };
    tod = super.callPackage ./pkgs/tod {
      inherit (nvfetcherSources.tod) src version;
      nvCargoLock = nvfetcherSources.tod.cargoLock;
    };
  };
  jackLib = import ./lib {pkgs = super;};
  nurAttrs =
    {
      lib = jackLib;
      modules = import ./modules;
      homeManagerModules = import ./modules/home-manager;
      darwinModules = import ./modules/nix-darwin;
      overlays = import ./overlays;
    }
    // jackLib.filterByPlatforms super.system allPackages;
in
  builtins.listToAttrs
  (map (n: nameValuePair n nurAttrs.${n})
    (builtins.filter (n: !isReserved n)
      (builtins.attrNames nurAttrs)))
