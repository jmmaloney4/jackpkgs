{
  # Default overlay with all packages from jackpkgs
  #
  # NOTE: deliberately NOT platform-filtered -- see the matching note in
  # ../overlay.nix. Filtering the exported attribute *names* by each
  # package's `meta.platforms` forces `callPackage` results from the final
  # package set this overlay is part of, which is an infinite recursion
  # (#384). `meta.platforms` is still enforced at build time by `checkMeta`.
  default = self: super: let
    nvfetcherSources = super.callPackage ../_sources/generated.nix {};
    packages = {
      csharpier = super.callPackage ../pkgs/csharpier {};
      gawkbot = super.callPackage ../pkgs/gawkbot {
        inherit (nvfetcherSources."gawkbot-${super.system}") src version;
      };
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
    packages;
}
