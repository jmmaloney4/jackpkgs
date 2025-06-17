{
  # Default overlay with all packages from jackpkgs
  default = self: super: {
    csharpier = super.callPackage ../pkgs/csharpier {};
    docfx = super.callPackage ../pkgs/docfx {};
    epub2tts = super.callPackage ../pkgs/epub2tts {};
    lean = super.callPackage ../pkgs/lean {};
    nbstripout = super.callPackage ../pkgs/nbstripout {};
    roon-server = super.callPackage ../pkgs/roon-server {};
  };
}
