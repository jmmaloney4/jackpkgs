# You can use this file as a nixpkgs overlay. This is useful in the
# case where you don't want to add the whole NUR namespace to your
# configuration.
self: super: let
  isReserved = n: n == "lib" || n == "overlays" || n == "modules";
  nameValuePair = n: v: {
    name = n;
    value = v;
  };
  # Define packages inline instead of importing default.nix
  allPackages = {
    csharpier = super.callPackage ./pkgs/csharpier {};
    docfx = super.callPackage ./pkgs/docfx {};
    epub2tts = super.callPackage ./pkgs/epub2tts {};
    lean = super.callPackage ./pkgs/lean {};
    roon-server = super.callPackage ./pkgs/roon-server {};
    tod = super.callPackage ./pkgs/tod {};
  };
  jackLib = import ./lib {pkgs = super;};
  nurAttrs =
    {
      lib = jackLib;
      modules = import ./modules;
      homeManagerModules = import ./modules/home-manager;
      overlays = import ./overlays;
    }
    // jackLib.filterByPlatforms super.system allPackages;
in
  builtins.listToAttrs
  (map (n: nameValuePair n nurAttrs.${n})
    (builtins.filter (n: !isReserved n)
      (builtins.attrNames nurAttrs)))
