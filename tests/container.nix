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

  # With fromImage set, fromImage is threaded through and config fields default to
  # "inherit": entrypoint/workingDir are omitted WITHOUT the caller setting them
  # (workingDir defaults to null for fromImage builds), so the base's config stands.
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

  # SSL_CERT_FILE is not auto-injected into a fromImage build with no explicit env
  # (it would replace the base's entire env); from-scratch images still get it.
  testFromImageSkipsSslEnvWhenNoEnv = let
    base = mkTestDerivation "base-image";
    cacert = (mkTestDerivation "cacert") // {pname = "cacert";};
    images = getFlakeImages [
      {
        jackpkgs.images.enable = true;
        jackpkgs.images.registry = "ghcr.io/example/jackpkgs";

        perSystem = {...}: {
          jackpkgs.images.commonPackages = [cacert];
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
      scratchHasSsl = builtins.any (e: lib.hasPrefix "SSL_CERT_FILE=" e) (images.scratch.config.Env or []);
      layeredOmitsEnv = !(images.layered.config ? Env);
    };
    expected = {
      scratchHasSsl = true;
      layeredOmitsEnv = true;
    };
  };

  # The shared common layer is kept by default (even for fromImage), and skipped
  # only when skipCommonLayer is set.
  testSkipCommonLayerOptOut = let
    base = mkTestDerivation "base-image";
    images = getFlakeImages [
      {
        jackpkgs.images.enable = true;
        jackpkgs.images.registry = "ghcr.io/example/jackpkgs";

        perSystem = {...}: {
          jackpkgs.images.commonPackages = [(mkTestDerivation "shared-common")];
          # fromImage WITHOUT opt-out keeps the common layer.
          jackpkgs.images.images.kept = {
            packages = [];
            fromImage = base;
          };
          # Explicit opt-out skips it.
          jackpkgs.images.images.skipped = {
            packages = [];
            fromImage = base;
            skipCommonLayer = true;
          };
        };
      }
    ];
  in {
    expr = {
      keptHasCommon = (builtins.elemAt images.kept.layers 0).ignoreCollisionsSeen or false;
      skippedNoCommon = images.skipped.layers == [];
    };
    expected = {
      keptHasCommon = true;
      skippedNoCommon = true;
    };
  };
}
