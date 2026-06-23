{
  # Default overlay with all packages from jackpkgs
  default = self: super: let
    jackLib = import ../lib {pkgs = super;};
    nvfetcherSources = super.callPackage ../_sources/generated.nix {};
    packages = {
      csharpier = super.callPackage ../pkgs/csharpier {};
      docfx = super.callPackage ../pkgs/docfx {};
      # epub2tts = super.callPackage ../pkgs/epub2tts {};
      # lean = super.callPackage ../pkgs/lean {};
      mcp-ynab = super.callPackage ../pkgs/mcp-ynab {
        inherit (nvfetcherSources.mcp-ynab) src version;
      };
      pulumi-drift-report = super.callPackage ../pkgs/pulumi-drift-report {};
      seedtool-cli = super.callPackage ../pkgs/seedtool-cli {};
      spooktacular = super.callPackage ../pkgs/spooktacular {
        inherit (nvfetcherSources.spooktacular) src date;
      };
      tod = super.callPackage ../pkgs/tod {
        inherit (nvfetcherSources.tod) src version;
        nvCargoLock = nvfetcherSources.tod.cargoLock;
      };
    };
  in
    jackLib.filterByPlatforms super.system packages;
}
