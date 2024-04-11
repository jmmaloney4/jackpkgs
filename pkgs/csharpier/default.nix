{
  dream2nix,
  config,
  lib,
  self,
  ...
}:
with config.deps; let
  pname = "CSharpier";
  version = "0.26.7";
  dotnetCoreSdk = dotnetCorePackages.sdk_8_0;
in rec {
  imports = [
    # dream2nix.modules.core.public
  ];

  name = lib.strings.toLower pname;
  inherit version;

  deps = {nixpkgs, ...}: {
    inherit
      (nixpkgs)
      stdenv
      dotnetCorePackages
      writeShellScriptBin
      fetchNuGet
      ;
  };

  public = let
    nuGet = fetchNuGet {
      inherit pname version;
      sha256 = "sha256-QVfbEtkj41/b8urLx8X274KWjawyfgPTIb9HOLfduB8=";
      outputFiles = ["tools/*"];
    };
  in
    writeShellScriptBin name ''${lib.getExe dotnetCoreSdk} ${nuGet}/lib/dotnet/CSharpier/net${lib.versions.majorMinor dotnetCoreSdk.version}/any/dotnet-csharpier.dll "$@";'';
}
