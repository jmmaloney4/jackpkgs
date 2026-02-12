{
  # Default overlay with all packages from jackpkgs
  default = self: super: let
    jackLib = import ../lib {pkgs = super;};
    packages = {
      csharpier = super.callPackage ../pkgs/csharpier {};
      docfx = super.callPackage ../pkgs/docfx {};
      pulumi-bin = super.pulumi-bin.overrideAttrs (old: {
        meta = (old.meta or {}) // {
          mainProgram = "pulumi";
        };
      });
      # epub2tts = super.callPackage ../pkgs/epub2tts {};
      # lean = super.callPackage ../pkgs/lean {};
      # roon-server = super.callPackage ../pkgs/roon-server {};
      tod = super.callPackage ../pkgs/tod {};
    };
  in
    jackLib.filterByPlatforms super.system packages;
}
