{
  stdenv,
  lib,
  dotnetCorePackages,
  writeShellScriptBin,
  fetchNuGet,
}: let
  csharpierNuGet = fetchNuGet {
    pname = "CSharpier";
    version = "0.26.0";
    sha256 = "sha256-Qz3DqqpWF8FmvwnQxIBsribgG+P2pFr45Ct+TFDuGBM=";
    outputFiles = ["tools/*"];
  };
in
  writeShellScriptBin "csharpier" ''
    ${lib.getExe dotnetCorePackages.sdk_7_0} ${csharpierNuGet}/lib/dotnet/CSharpier/net7.0/any/dotnet-csharpier.dll "$@";
  ''
