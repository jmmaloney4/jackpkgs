# Tests for the nodeModules derivation built by modules/flake-parts/nodejs.nix
{
  lib,
  inputs,
}: let
  system = "x86_64-linux";
  flakeParts = inputs.flake-parts.lib;

  pkgsModule = import ../modules/flake-parts/pkgs.nix {jackpkgsInputs = inputs;};
  shellModule = import ../modules/flake-parts/devshell.nix {jackpkgsInputs = inputs;};
  nodejsModule = import ../modules/flake-parts/nodejs.nix {jackpkgsInputs = inputs;};

  perSystem =
    (flakeParts.evalFlakeModule {inherit inputs;} {
      systems = [system];
      imports = [
        pkgsModule
        shellModule
        nodejsModule
        {
          _module.check = false;
          jackpkgs.nodejs = {
            enable = true;
            pnpmDepsHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
            projectRoot = ./fixtures/checks/pnpm-workspace;
          };
        }
      ];
    }).config.perSystem
    system;

  attrs = perSystem.jackpkgs.outputs.nodeModules.drvAttrs;
in {
  # #449: auditTmpdir is skipped (it dominates fixup and guards nothing in a
  # pnpm tree), but fixup itself still runs, so patchShebangs and the ADR-047
  # noBrokenSymlinks guard stay in force.
  testNodeModulesFixupContract = {
    expr = {
      noAuditTmpdir = attrs.noAuditTmpdir or false;
      dontFixup = attrs.dontFixup or false;
      dontPatchShebangs = attrs.dontPatchShebangs or false;
      dontCheckForBrokenSymlinks = attrs.dontCheckForBrokenSymlinks or false;
    };
    expected = {
      noAuditTmpdir = true;
      dontFixup = false;
      dontPatchShebangs = false;
      dontCheckForBrokenSymlinks = false;
    };
  };
}
