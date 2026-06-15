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

  # Even with the common layer kept (cacert present), SSL_CERT_FILE is not
  # auto-injected into a fromImage build with no explicit env (it would replace the
  # base's entire env). From-scratch images still get it.
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
            skipCommonLayer = false; # keep common so cacert is present
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

  # skipCommonLayer defaults to true for fromImage (skip) and is overridable.
  testSkipCommonLayerDefaultAndOverride = let
    base = mkTestDerivation "base-image";
    images = getFlakeImages [
      {
        jackpkgs.images.enable = true;
        jackpkgs.images.registry = "ghcr.io/example/jackpkgs";

        perSystem = {...}: {
          jackpkgs.images.commonPackages = [(mkTestDerivation "shared-common")];
          # fromImage default: skip the common layer.
          jackpkgs.images.images.defaultSkips = {
            packages = [];
            fromImage = base;
          };
          # Override to keep it (e.g. a distroless base needing userland).
          jackpkgs.images.images.keptViaOverride = {
            packages = [];
            fromImage = base;
            skipCommonLayer = false;
          };
        };
      }
    ];
  in {
    expr = {
      defaultSkipsCommon = images.defaultSkips.layers == [];
      keptHasCommon = (builtins.elemAt images.keptViaOverride.layers 0).ignoreCollisionsSeen or false;
    };
    expected = {
      defaultSkipsCommon = true;
      keptHasCommon = true;
    };
  };
}
