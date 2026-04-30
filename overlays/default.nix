{
  # Default overlay with all packages from jackpkgs
  default = self: super: let
    jackLib = import ../lib {pkgs = super;};
    packages = {
      csharpier = super.callPackage ../pkgs/csharpier {};
      docfx = super.callPackage ../pkgs/docfx {};
      # epub2tts = super.callPackage ../pkgs/epub2tts {};
      # lean = super.callPackage ../pkgs/lean {};
      seedtool-cli = super.callPackage ../pkgs/seedtool-cli {};
      tod = super.callPackage ../pkgs/tod {};
    };
  in
    jackLib.filterByPlatforms super.system packages;
}
