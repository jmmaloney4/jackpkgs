{
  description = "My personal NUR repository";

  inputs = {
    # nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nixpkgs.url = "github:NixOS/nixpkgs/70801e06d9730c4f1704fbd3bbf5b8e11c03a2a7"; # https://github.com/NixOS/nixpkgs/issues/483584
    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-iter = {
      url = "github:DeterminateSystems/flake-iter";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.fenix.follows = "fenix";
    };
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    flake-root.url = "github:srid/flake-root";
    flake-compat = {
      url = "github:NixOS/flake-compat";
      flake = false;
    };
    gitignore = {
      url = "github:hercules-ci/gitignore.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    just-flake = {
      url = "github:juspay/just-flake";
    };
    llm-agents = {
      url = "github:numtide/llm-agents.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-unit = {
      url = "github:nix-community/nix-unit";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-parts.follows = "flake-parts";
      inputs.treefmt-nix.follows = "treefmt";
    };
    pre-commit-hooks = {
      url = "github:cachix/pre-commit-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.gitignore.follows = "gitignore";
      inputs.flake-compat.follows = "flake-compat";
      # inputs.flake-utils.inputs.systems.follows = "systems";
    };
    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
    };
    systems.url = "github:nix-systems/default";
    treefmt = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
    };
    bun2nix = {
      url = "github:nix-community/bun2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs @ {
    self,
    flake-parts,
    systems,
    ...
  }:
    flake-parts.lib.mkFlake {inherit inputs;} {
      systems = import systems;

      # Import our flake modules
      imports = [
        # expose flake-parts modules for consumers
        ./modules/flake-parts

        # dogfood our own flake-parts modules
        (import ./modules/flake-parts/all.nix {jackpkgsInputs = inputs;})
        inputs.nix-unit.modules.flake.default
      ];

      jackpkgs.pulumi.enable = false;

      perSystem = {
        system,
        pkgs,
        lib,
        config,
        self',
        ...
      }: let
        jackLib = import ./lib {inherit pkgs;};
        # Make flake lib available for tests
        flakeLib = inputs.nixpkgs.lib.extend (
          final: prev: jackLib
        );
        allPackages = {
          csharpier = pkgs.callPackage ./pkgs/csharpier {};
          docfx = pkgs.callPackage ./pkgs/docfx {};
          epub2tts = pkgs.callPackage ./pkgs/epub2tts {};
          lean = pkgs.callPackage ./pkgs/lean {};
          openchamber = pkgs.callPackage ./pkgs/openchamber {
            opencode = inputs.llm-agents.packages.${system}.opencode;
            bun2nix-cli = inputs.bun2nix.packages.${system}.bun2nix;
          };
          roon-server = pkgs.callPackage ./pkgs/roon-server {};
          tod = pkgs.callPackage ./pkgs/tod {};
        };
        platformFilteredPackages = jackLib.filterByPlatforms system allPackages;
        # Import test helpers that validate the flake-exposed API surface
        testHelpers = import ./tests/test-helpers.nix {lib = flakeLib;};
        # Import justfile validation tests (these return derivations directly)
        justfileValidationTests = import ./tests/justfile-validation.nix {
          inherit lib pkgs testHelpers;
        };
        # Import module pattern tests (test patterns used in actual module features)
        moduleJustfileTests = import ./tests/module-justfiles.nix {
          inherit lib pkgs testHelpers;
        };

        integrationFixturesRoot = ./tests/fixtures/integration;
        fixtureSimplePnpm = integrationFixturesRoot + "/simple-pnpm";
        fixtureWorkspaceBasic = integrationFixturesRoot + "/pnpm-workspace-basic";
        fixtureWorkspaceGlob = integrationFixturesRoot + "/pnpm-workspace-glob";
        fixtureTscCheck = integrationFixturesRoot + "/pnpm-tsc-check";
        fixtureVitestCheck = integrationFixturesRoot + "/pnpm-vitest-check";
        fixtureNonhoistedDep = integrationFixturesRoot + "/pnpm-workspace-nonhoisted-dep";

        mkPnpmFixtureCheck = {
          name,
          src,
          depsHash,
          checkCommand,
          extraAttrs ? {},
          pnpmDepsArgs ? {},
        }: let
          cleanSrc = lib.cleanSourceWith {
            inherit src;
            filter = path: _type: builtins.baseNameOf path != "node_modules";
          };
        in
          pkgs.stdenv.mkDerivation ({
              pname = "integration-${name}";
              version = "1.0.0";
              src = cleanSrc;
              pnpmDeps = pkgs.fetchPnpmDeps ({
                  pname = "integration-${name}-deps";
                  version = "1.0.0";
                  src = cleanSrc;
                  hash = depsHash;
                  fetcherVersion = 3;
                }
                // pnpmDepsArgs);
              nativeBuildInputs = [
                pkgs.nodejs
                pkgs.pnpm_10
                pkgs.pnpmConfigHook
              ];
              dontBuild = true;
              installPhase = ''
                runHook preInstall
                ${checkCommand}
                mkdir -p "$out"
                runHook postInstall
              '';
            }
            // extraAttrs);
      in {
        # Make jackLib and platformFilteredPackages available for devShell
        _module.args.jackpkgs =
          {
            lib = jackLib;
            modules = import ./modules;
            homeManagerModules = import ./modules/home-manager;
            overlays = import ./overlays;
          }
          // platformFilteredPackages;

        packages =
          lib.filterAttrs (
            _: v:
              lib.isDerivation v
              && !(v.meta.broken or false)
          )
          platformFilteredPackages;

        devShells.default = pkgs.mkShell {
          inputsFrom = [
            config.jackpkgs.outputs.devShell
          ];
          packages = [
          ];
        };

        nix-unit = let
          # Provide nix-unit with our flake inputs so it never needs network access.
          # Convert flake inputs to their realised store paths where possible.
          sanitizeInput = input:
            if builtins.isAttrs input && input ? outPath
            then input.outPath
            else input;
          # Pass all inputs including nix-unit, plus aliases and nested overrides
          nixUnitInputs =
            (builtins.mapAttrs (_: sanitizeInput) (builtins.removeAttrs inputs ["self"]))
            // {
              # nix-unit expects an input named 'treefmt-nix', but we call it 'treefmt'
              treefmt-nix = sanitizeInput inputs.treefmt;
              # Override nix-unit's own flake-parts dependency to use ours
              "nix-unit/flake-parts" = sanitizeInput inputs.flake-parts;
              "nix-unit/nixpkgs" = sanitizeInput inputs.nixpkgs;
              "nix-unit/treefmt-nix" = sanitizeInput inputs.treefmt;
            };
        in {
          package = inputs.nix-unit.packages.${system}.default;
          inputs = nixUnitInputs;
          tests = {
            mkRecipe = import ./tests/mkRecipe.nix {
              inherit lib testHelpers;
            };
            mkRecipeWithParams = import ./tests/mkRecipeWithParams.nix {
              inherit lib testHelpers;
            };
            optionalLines = import ./tests/optionalLines.nix {
              inherit lib testHelpers;
            };
            checks = import ./tests/checks.nix {
              inherit inputs lib;
            };
            pre-commit = import ./tests/pre-commit.nix {
              inherit inputs lib;
            };
            pkgs = import ./tests/pkgs.nix {
              inherit inputs lib;
            };
          };
        };

        checks =
          # Add all justfile validation tests
          lib.mapAttrs' (name: test: lib.nameValuePair "justfile-${name}" test) justfileValidationTests
          # Add module pattern tests
          // lib.mapAttrs' (name: test: lib.nameValuePair "module-${name}" test) moduleJustfileTests
          // {
            pnpm-simple-builds = mkPnpmFixtureCheck {
              name = "simple-pnpm";
              src = fixtureSimplePnpm;
              depsHash = "sha256-Y6FY9XiRcBAgaz2T0E90up0bABCBGl81uqZx1vbDRL8=";
              checkCommand = ''
                test -d node_modules
                node index.js | grep -qx "pass"
              '';
            };

            pnpm-workspace-basic-postinstall = mkPnpmFixtureCheck {
              name = "workspace-basic";
              src = fixtureWorkspaceBasic;
              depsHash = "sha256-4ym+vvg1zaiIKtF1Bzfb5AF/njvUBauh6gbB3uR/eWU=";
              checkCommand = ''
                test -d node_modules
                pnpm run postinstall
                test -f lib/dist/index.js
                node --input-type=module -e "const lib = await import('./lib/dist/index.js'); if (lib.add(2, 3) !== 5) process.exit(1);"
              '';
            };

            pnpm-workspace-glob-resolution = mkPnpmFixtureCheck {
              name = "workspace-glob";
              src = fixtureWorkspaceGlob;
              depsHash = "sha256-wuZJSJ4/SYJCOTFYTW1RXrdvn3D1tY6gbMGgou1zoLQ=";
              checkCommand = ''
                test -d node_modules
                node packages/beta/index.js | grep -qx "hello from alpha"
              '';
            };

            pnpm-tsc-check = mkPnpmFixtureCheck {
              name = "tsc-check";
              src = fixtureTscCheck;
              depsHash = "sha256-4ym+vvg1zaiIKtF1Bzfb5AF/njvUBauh6gbB3uR/eWU=";
              checkCommand = ''
                test -d node_modules
                node_modules/.bin/tsc --noEmit --lib ES2020,DOM packages/app/index.ts
              '';
            };

            pnpm-vitest-check = mkPnpmFixtureCheck {
              name = "vitest-check";
              src = fixtureVitestCheck;
              depsHash = "sha256-+Yuu23jx65TFnR5F71dDWU8SjFypZpaFdu+GGLe9qQ8=";
              checkCommand = ''
                test -d node_modules
                node_modules/.bin/vitest run --root packages/lib
              '';
            };

            pnpm-node-modules-output-layout = mkPnpmFixtureCheck {
              name = "node-modules-output-layout";
              src = fixtureWorkspaceBasic;
              depsHash = "sha256-4ym+vvg1zaiIKtF1Bzfb5AF/njvUBauh6gbB3uR/eWU=";
              checkCommand = ''
                mkdir -p "$out"
                cp -a node_modules "$out/"
                test -d "$out/node_modules"
                test -L "$out/node_modules/.pnpm/node_modules/@test/lib"
                test ! -e "$out/node_modules/.pnpm/node_modules/@test/lib"
              '';
              extraAttrs = {
                dontCheckForBrokenSymlinks = true;
              };
            };

            pnpm-nonhoisted-runtime = mkPnpmFixtureCheck {
              name = "nonhoisted-runtime";
              src = fixtureNonhoistedDep;
              depsHash = "sha256-Pyw+kyJeLDLPK9pkYvuT2/V7yg5kawHzMwY8B4thNEk=";
              checkCommand = ''
                test -d node_modules
                node packages/app/index.js | grep -qx "pass"
              '';
              # Darwin workaround: fetchPnpmDeps fails with "chmod: missing operand"
              # when no *-exec files exist. Sentinel satisfies chmod glob.
              pnpmDepsArgs = {
                prePnpmInstall = ''
                  touch "$storePath/fetcher-sentinel-exec"
                '';
              };
            };

            # Mirrors nodejs.nix:125-129 installPhase; keep in sync.
            pnpm-nonhoisted-output-layout = mkPnpmFixtureCheck {
              name = "nonhoisted-output-layout";
              src = fixtureNonhoistedDep;
              depsHash = "sha256-Pyw+kyJeLDLPK9pkYvuT2/V7yg5kawHzMwY8B4thNEk=";
              checkCommand = ''
                mkdir -p "$out"
                cp -a node_modules "$out/"
                find . -mindepth 2 -name 'node_modules' -type d \
                  -not -path './node_modules/*' | while read -r dir; do
                  mkdir -p "$out/$(dirname "$dir")"
                  cp -a "$dir" "$out/$dir"
                done

                test -d "$out/node_modules"
                test ! -e "$out/node_modules/is-odd"
                test -L "$out/packages/app/node_modules/is-odd"
                test -z "$(find "$out/node_modules/.pnpm" -path '*/node_modules/node_modules' -print -quit)"
              '';
              extraAttrs = {
                dontCheckForBrokenSymlinks = true;
              };
              # Darwin workaround: fetchPnpmDeps fails with "chmod: missing operand"
              # when no *-exec files exist. Sentinel satisfies chmod glob.
              pnpmDepsArgs = {
                prePnpmInstall = ''
                  touch "$storePath/fetcher-sentinel-exec"
                '';
              };
            };
          };
      };

      flake = {
        # Expose overlays for backward compatibility
        overlays.default = import ./overlay.nix;

        # Expose lib for backward compatibility
        lib = inputs.nixpkgs.lib.extend (
          final: prev:
            import ./lib {pkgs = inputs.nixpkgs.legacyPackages.${builtins.head (import inputs.systems)};}
        );

        # Expose just templates
        templates = {
          just = {
            path = ./templates/default;
            description = "just-flake template";
          };
        };
      };
    };
}
