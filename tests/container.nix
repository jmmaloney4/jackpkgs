{
  lib,
  inputs,
}: let
  system = "x86_64-linux";
  flakeParts = inputs.flake-parts.lib;

  mkTestDerivation = name:
    builtins.derivation {
      inherit name system;
      builder = "/bin/sh";
      args = [
        "-c"
        ''
          mkdir -p "$out"
          touch "$out"/${lib.escapeShellArg name}
        ''
      ];
    };

  fakeInputs =
    inputs
    // {
      nixpkgs = {
        legacyPackages.${system} = {
          buildEnv = args:
            if args ? ignoreCollisions && args.ignoreCollisions
            then {
              inherit args;
              ignoreCollisionsSeen = true;
            }
            else builtins.throw "jackpkgs.images should enable ignoreCollisions on the shared buildEnv";
        };
      };

      nix2container = {
        packages.${system} = {
          nix2container = {
            buildLayer = {copyToRoot, ...} @ args: copyToRoot;
            buildImage = args: args;
          };
          skopeo-nix2container = mkTestDerivation "skopeo-nix2container";
        };
      };
    };

  containerModule = import ../modules/flake-parts/container.nix {
    jackpkgsInputs = fakeInputs;
  };
  justModule = import ../modules/flake-parts/just.nix {jackpkgsInputs = fakeInputs;};

  evalFlake = modules:
    flakeParts.evalFlakeModule {inherit inputs;} {
      systems = [system];
      imports =
        [
          {
            _module.check = false;
          }
          justModule
          containerModule
        ]
        ++ modules;
    };

  getFlakeImages = modules: (evalFlake modules).config.flake.images;
in {
  testCommonLayerBuildEnvEnablesIgnoreCollisions = let
    images = getFlakeImages [
      {
        jackpkgs.images.enable = true;
        jackpkgs.images.registry = "ghcr.io/example/jackpkgs";

        perSystem = {...}: {
          jackpkgs.images.commonPackages = [
            (mkTestDerivation "shared-common-package")
          ];
          jackpkgs.images.images.demo = {
            packages = [];
          };
        };
      }
    ];
  in {
    expr = (builtins.elemAt images.demo.layers 0).ignoreCollisionsSeen or false;
    expected = true;
  };

  # Without fromImage, the arg is omitted entirely (from-scratch), not passed null.
  testFromImageDefaultsToScratch = let
    images = getFlakeImages [
      {
        jackpkgs.images.enable = true;
        jackpkgs.images.registry = "ghcr.io/example/jackpkgs";

        perSystem = {...}: {
          jackpkgs.images.commonPackages = [];
          jackpkgs.images.images.demo.packages = [];
        };
      }
    ];
  in {
    expr = images.demo ? fromImage;
    expected = false;
  };

  # With fromImage set and config fields left empty/null, fromImage is threaded
  # through and those fields are omitted so the base image's config is inherited.
  testFromImagePassthroughAndInherits = let
    base = mkTestDerivation "base-image";
    images = getFlakeImages [
      {
        jackpkgs.images.enable = true;
        jackpkgs.images.registry = "ghcr.io/example/jackpkgs";

        perSystem = {...}: {
          jackpkgs.images.commonPackages = [];
          jackpkgs.images.images.layered = {
            packages = [];
            fromImage = base;
            entrypoint = [];
            workingDir = null;
          };
        };
      }
    ];
  in {
    expr = {
      hasFromImage = images.layered.fromImage == base;
      omitsEntrypoint = !(images.layered.config ? Entrypoint);
      omitsWorkingDir = !(images.layered.config ? WorkingDir);
    };
    expected = {
      hasFromImage = true;
      omitsEntrypoint = true;
      omitsWorkingDir = true;
    };
  };

  # fromImage images skip the shared common layer (the base provides userland);
  # from-scratch images still get it.
  testFromImageSkipsCommonLayer = let
    base = mkTestDerivation "base-image";
    images = getFlakeImages [
      {
        jackpkgs.images.enable = true;
        jackpkgs.images.registry = "ghcr.io/example/jackpkgs";

        perSystem = {...}: {
          jackpkgs.images.commonPackages = [(mkTestDerivation "shared-common")];
          jackpkgs.images.images.scratch.packages = [];
          jackpkgs.images.images.layered = {
            packages = [];
            fromImage = base;
          };
        };
      }
    ];
  in {
    expr = {
      scratchHasCommon = (builtins.elemAt images.scratch.layers 0).ignoreCollisionsSeen or false;
      layeredNoCommon = images.layered.layers == [];
    };
    expected = {
      scratchHasCommon = true;
      layeredNoCommon = true;
    };
  };
}
