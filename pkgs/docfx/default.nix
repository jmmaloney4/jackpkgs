{
  dream2nix,
  config,
  lib,
  self,
  ...
}:
with config.deps; let
  pname = "docfx";
  version = "2.75.1";
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
    nuGet =
      (fetchNuGet {
        inherit pname version;
        sha256 = "sha256-bbD4+yNxM4vmZXPczeFH+Hy5IohKVA2cIrb+88tLD8Y=";
        outputFiles = ["*"];
      })
      .overrideAttrs (old: {
        postUnpack = ''
          chmod +x tools/.playwright/node/*/playwright.sh
          chmod +x tools/.playwright/node/*/node
        '';
      });
  in
    writeShellScriptBin name ''${lib.getExe dotnetCoreSdk} ${nuGet}/lib/dotnet/docfx/tools/net${lib.versions.majorMinor dotnetCoreSdk.version}/any/docfx.dll "$@"'';
}
