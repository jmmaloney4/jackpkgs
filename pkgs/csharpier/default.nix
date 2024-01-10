{
  stdenv,
  lib,
  dotnetCorePackages,
  writeShellScriptBin,
  fetchNuGet,
}: let
  csharpierNuGet = fetchNuGet {
    pname = "CSharpier";
    version = "0.26.7";
    sha256 = "sha256-QVfbEtkj41/b8urLx8X274KWjawyfgPTIb9HOLfduB8=";
    outputFiles = ["tools/*"];
  };
in
  writeShellScriptBin "csharpier" ''
    ${lib.getExe dotnetCorePackages.sdk_7_0} ${csharpierNuGet}/lib/dotnet/CSharpier/net7.0/any/dotnet-csharpier.dll "$@";
  ''
