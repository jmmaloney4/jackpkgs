{
  # Default overlay with all packages from jackpkgs
  default = self: super: let
    jackLib = import ../lib {pkgs = super;};
    nvfetcherSources = super.callPackage ../_sources/generated.nix {};
    packages = {
      csharpier = super.callPackage ../pkgs/csharpier {};
      docfx = super.callPackage ../pkgs/docfx {};
      # epub2tts = super.callPackage ../pkgs/epub2tts {};
      seedtool-cli = super.callPackage ../pkgs/seedtool-cli {};
      mcp-ynab = super.callPackage ../pkgs/mcp-ynab {
        inherit (nvfetcherSources.mcp-ynab) src version;
      };
      spooktacular = super.callPackage ../pkgs/spooktacular {
        inherit (nvfetcherSources.spooktacular) src date;
      };
      tauceti = super.callPackage ../pkgs/tauceti {
        inherit (nvfetcherSources.tauceti) src date;
        inherit (packages) tauceti-review tauceti-progress;
      };
      tauceti-progress = super.callPackage ../pkgs/tauceti-progress {
        inherit (nvfetcherSources.tauceti-progress) src version;
      };
      tauceti-review = super.callPackage ../pkgs/tauceti-review {
        inherit (nvfetcherSources.tauceti-review) src version;
      };
      tod = super.callPackage ../pkgs/tod {
        inherit (nvfetcherSources.tod) src version;
        nvCargoLock = nvfetcherSources.tod.cargoLock;
      };
    };
  in
    jackLib.filterByPlatforms super.system packages;
}
