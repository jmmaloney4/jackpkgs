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

  evalFlakeWith = evalInputs: modules:
    flakeParts.evalFlakeModule {inputs = evalInputs;} {
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

  getFlakeImages = modules: (evalFlakeWith inputs modules).config.flake.images;

  # The module reads the CONSUMER flake's revision via `inputs.self`. The real
  # `inputs.self` is nondeterministic (clean in CI -> rev, dirty in dev ->
  # dirtyRev), so override `self` to exercise each case deterministically.
  # Strip the conflicting rev attrs first so `a.rev or a.dirtyRev` resolves the
  # intended branch regardless of how the real checkout was evaluated.
  withSelf = selfAttrs: inputs // {self = (builtins.removeAttrs inputs.self ["rev" "shortRev" "dirtyRev" "dirtyShortRev"]) // selfAttrs;};
  getFlakeImagesWithSelf = selfAttrs: modules: (evalFlakeWith (withSelf selfAttrs) modules).config.flake.images;
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

  # labels populate config.Labels when set, and the key is omitted entirely when
  # left at the default (so a fromImage base's own labels are not clobbered).
  testLabels = let
    base = mkTestDerivation "base-image";
    images = getFlakeImages [
      {
        jackpkgs.images.enable = true;
        jackpkgs.images.registry = "ghcr.io/example/jackpkgs";

        perSystem = {...}: {
          jackpkgs.images.commonPackages = [];
          jackpkgs.images.images.labeled = {
            packages = [];
            labels."org.opencontainers.image.source" = "https://github.com/jmmaloney4/jackpkgs";
          };
          # No labels set, fromImage base: Labels must be omitted so the base's
          # labels stand (nix2container merges, but we still avoid an empty map).
          jackpkgs.images.images.unlabeled = {
            packages = [];
            fromImage = base;
          };
        };
      }
    ];
  in {
    expr = {
      sourceLabel = images.labeled.config.Labels."org.opencontainers.image.source" or null;
      unlabeledOmitsLabels = !(images.unlabeled.config ? Labels);
    };
    expected = {
      sourceLabel = "https://github.com/jmmaloney4/jackpkgs";
      unlabeledOmitsLabels = true;
    };
  };

  # Global jackpkgs.images.labels merge into every image, with per-image labels
  # winning on key collisions.
  testGlobalLabelsMergeAndPrecedence = let
    images = getFlakeImages [
      {
        jackpkgs.images.enable = true;
        jackpkgs.images.registry = "ghcr.io/example/jackpkgs";
        jackpkgs.images.labels = {
          "org.opencontainers.image.source" = "https://github.com/jmmaloney4/jackpkgs";
          "com.example.team" = "platform";
        };

        perSystem = {...}: {
          jackpkgs.images.commonPackages = [];
          jackpkgs.images.images.demo = {
            packages = [];
            # Per-image override of a global key.
            labels."com.example.team" = "data";
          };
        };
      }
    ];
  in {
    expr = {
      inheritsGlobal = images.demo.config.Labels."org.opencontainers.image.source" or null;
      perImageWins = images.demo.config.Labels."com.example.team" or null;
    };
    expected = {
      inheritsGlobal = "https://github.com/jmmaloney4/jackpkgs";
      perImageWins = "data";
    };
  };

  # addRevisionLabel on a CLEAN consumer tree injects the commit SHA.
  testRevisionLabelClean = let
    images = getFlakeImagesWithSelf {rev = "1111111111111111111111111111111111111111";} [
      {
        jackpkgs.images.enable = true;
        jackpkgs.images.registry = "ghcr.io/example/jackpkgs";
        jackpkgs.images.addRevisionLabel = true;

        perSystem = {...}: {
          jackpkgs.images.commonPackages = [];
          jackpkgs.images.images.demo.packages = [];
        };
      }
    ];
  in {
    expr = images.demo.config.Labels."org.opencontainers.image.revision" or null;
    expected = "1111111111111111111111111111111111111111";
  };

  # addRevisionLabel on a DIRTY consumer tree falls back to dirtyRev, which
  # already carries the "-dirty" suffix.
  testRevisionLabelDirty = let
    images = getFlakeImagesWithSelf {dirtyRev = "2222222222222222222222222222222222222222-dirty";} [
      {
        jackpkgs.images.enable = true;
        jackpkgs.images.registry = "ghcr.io/example/jackpkgs";
        jackpkgs.images.addRevisionLabel = true;

        perSystem = {...}: {
          jackpkgs.images.commonPackages = [];
          jackpkgs.images.images.demo.packages = [];
        };
      }
    ];
  in {
    expr = images.demo.config.Labels."org.opencontainers.image.revision" or null;
    expected = "2222222222222222222222222222222222222222-dirty";
  };

  # No git info (neither rev nor dirtyRev): the revision label is omitted rather
  # than emitting a placeholder, and with no other labels Labels is absent.
  testRevisionLabelOmittedWhenNoGit = let
    images = getFlakeImagesWithSelf {} [
      {
        jackpkgs.images.enable = true;
        jackpkgs.images.registry = "ghcr.io/example/jackpkgs";
        jackpkgs.images.addRevisionLabel = true;

        perSystem = {...}: {
          jackpkgs.images.commonPackages = [];
          jackpkgs.images.images.demo.packages = [];
        };
      }
    ];
  in {
    expr = images.demo.config ? Labels;
    expected = false;
  };

  # Per-image labels override the auto-injected revision on key collision.
  testRevisionLabelOverriddenPerImage = let
    images = getFlakeImagesWithSelf {rev = "3333333333333333333333333333333333333333";} [
      {
        jackpkgs.images.enable = true;
        jackpkgs.images.registry = "ghcr.io/example/jackpkgs";
        jackpkgs.images.addRevisionLabel = true;

        perSystem = {...}: {
          jackpkgs.images.commonPackages = [];
          jackpkgs.images.images.demo = {
            packages = [];
            labels."org.opencontainers.image.revision" = "pinned";
          };
        };
      }
    ];
  in {
    expr = images.demo.config.Labels."org.opencontainers.image.revision" or null;
    expected = "pinned";
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
