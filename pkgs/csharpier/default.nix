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
in {
  imports = [
    # dream2nix.modules.core.public
  ];

  name = "csharpier";
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
      pname = "CSharpier";
      version = "0.26.7";
      sha256 = "sha256-QVfbEtkj41/b8urLx8X274KWjawyfgPTIb9HOLfduB8=";
      outputFiles = ["tools/*"];
    };
    dotnetCoreSdk = dotnetCorePackages.sdk_8_0;
  in
    writeShellScriptBin "csharpier" ''${lib.getExe dotnetCoreSdk} ${nuGet}/lib/dotnet/CSharpier/net${lib.versions.majorMinor dotnetCoreSdk.version}/any/dotnet-csharpier.dll "$@";'';
}
