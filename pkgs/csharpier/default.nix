{
  stdenv,
  lib,
  dotnetCorePackages,
  writeShellScriptBin,
  fetchNuGet,
  dotnetCoreSdk ? dotnetCorePackages.sdk_7_0,
}: let
  nuGet = fetchNuGet {
    pname = "CSharpier";
    version = "0.26.7";
    sha256 = "sha256-QVfbEtkj41/b8urLx8X274KWjawyfgPTIb9HOLfduB8=";
    outputFiles = ["tools/*"];
  };
in
  writeShellScriptBin "csharpier" ''
    ${lib.getExe dotnetCoreSdk} ${nuGet}/lib/dotnet/CSharpier/net${lib.versions.majorMinor dotnetCoreSdk.version}/any/dotnet-csharpier.dll "$@";
  ''
