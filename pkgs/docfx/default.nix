{
  stdenv,
  lib,
  dotnetCorePackages,
  writeShellScriptBin,
  fetchNuGet,
  dotnetCoreSdk ? dotnetCorePackages.sdk_7_0,
}: let
  nuget = fetchNuGet {
    pname = "docfx";
    version = "2.75.1";
    sha256 = "sha256-bbD4+yNxM4vmZXPczeFH+Hy5IohKVA2cIrb+88tLD8Y=";
    outputFiles = ["tools/*"];
  };
in
  writeShellScriptBin "docfx" ''
    ${lib.getExe dotnetCoreSdk} ${nuget}/lib/dotnet/docfx/net${lib.versions.majorMinor dotnetCoreSdk.version}/any/docfx.dll "$@";
  ''
