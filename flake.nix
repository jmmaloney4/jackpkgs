{
  description = "My personal NUR repository";

  inputs = {
    # nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
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

    nix-unit = {
      url = "github:nix-community/nix-unit";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.treefmt-nix.follows = "treefmt";
    };
    nix2container = {
      url = "github:nlewo/nix2container";
      inputs.nixpkgs.follows = "nixpkgs";
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
        nvfetcherSources = pkgs.callPackage ./_sources/generated.nix {};
        # Extend pkgs with bun2nix overlay so bun2nix builder functions are available
        pkgsWithBun2nix = pkgs.extend inputs.bun2nix.overlays.default;
        nautilusRustToolchain = inputs.fenix.packages.${system}.minimal.toolchain;
        nautilusRustPlatform = pkgs.makeRustPlatform {
          cargo = nautilusRustToolchain;
          rustc = nautilusRustToolchain;
        };
        # Make flake lib available for tests
        flakeLib = inputs.nixpkgs.lib.extend (
          final: prev: jackLib
        );
        allPackages = {
          csharpier = pkgs.callPackage ./pkgs/csharpier {};
          codex-proxy = pkgs.callPackage ./pkgs/codex-proxy {
            inherit (nvfetcherSources.codex-proxy) src version;
          };
          codex-proxy-rs = pkgs.callPackage ./pkgs/codex-proxy-rs {
            inherit (nvfetcherSources.codex-proxy-rs) src version;
          };
          docfx = pkgs.callPackage ./pkgs/docfx {};
          gemini-proxy = pkgsWithBun2nix.callPackage ./pkgs/gemini-proxy {
            inherit (nvfetcherSources.gemini-proxy) src version;
          };
          epub2tts = pkgs.callPackage ./pkgs/epub2tts {};
          imessage-bridge = pkgs.callPackage ./pkgs/imessage-bridge {};
          lean = pkgs.callPackage ./pkgs/lean {};
          mcp-ynab = pkgs.callPackage ./pkgs/mcp-ynab {
            inherit (nvfetcherSources.mcp-ynab) src version;
          };
          nautilus-trader = pkgs.callPackage ./pkgs/nautilus-trader {
            inherit (nvfetcherSources.nautilus-trader) src version cargoLock;
            cargo = nautilusRustToolchain;
            rustc = nautilusRustToolchain;
            rustPlatform = nautilusRustPlatform;
            # Keep the legacy override parameter for `.override { python312 = ...; }` callers.
            # The default value now comes from Python 3.14.
            python312 = pkgs.python314;
          };
          seedtool-cli = pkgs.callPackage ./pkgs/seedtool-cli {};
          # Re-export skopeo-nix2container from the nix2container flake so it is
          # built once and pushed to our binary cache, instead of every consumer
          # rebuilding it from `github:nlewo/nix2container#...`. The tagged
          # v1.0.0 release fetches a skopeo patch from a GitHub commit URL whose
          # fixed-output hash GitHub has since broken, so building it fresh fails;
          # our pinned input (HEAD) ships skopeo-1.22.2 without that patch.
          # Consumed by sector7's image-push scripts to read/push nix images.
          skopeo-nix2container = inputs.nix2container.packages.${system}.skopeo-nix2container;
          spooktacular = pkgs.callPackage ./pkgs/spooktacular {
            inherit (nvfetcherSources.spooktacular) src date;
          };
          tod = pkgs.callPackage ./pkgs/tod {
            inherit (nvfetcherSources.tod) src version;
            nvCargoLock = nvfetcherSources.tod.cargoLock;
          };
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
              pnpmDeps = pkgs.fetchPnpmDeps (
                {
                  pname = "integration-${name}-deps";
                  version = "1.0.0";
                  src = cleanSrc;
                  hash = depsHash;
                  fetcherVersion = 3;
                  pnpm = pkgs.pnpm_11;
                }
                // ({
                    # On some fixtures, fetchPnpmDeps fixup's `find ... | xargs chmod`
                    # receives empty input and invokes chmod with no operands.
                    # Use GNU xargs `-r` in this derivation to no-op on empty input,
                    # without modifying fetched pnpm store contents.
                    preFixup = ''
                      xargs() {
                        command xargs -r "$@"
                      }
                      ${pnpmDepsArgs.preFixup or ""}
                    '';
                  }
                  // pnpmDepsArgs)
              );
              nativeBuildInputs = [
                pkgs.nodejs_24
                pkgs.pnpm_11
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

        # pnpm integration fixtures. Each is a full build (pnpm install + checkCommand),
        # aggregated into the single `fixture-tests` check below rather than exposed
        # individually.
        pnpmFixtureChecks = {
          pnpm-simple-builds = mkPnpmFixtureCheck {
            name = "simple-pnpm";
            src = fixtureSimplePnpm;
            depsHash = "sha256-R0X9msP0FeYEOnoO5rDwpykuj7FgWqEM8cGvZHwrvOc=";
            checkCommand = ''
              test -d node_modules
              node index.js | grep -qx "pass"
            '';
          };

          pnpm-workspace-basic-postinstall = mkPnpmFixtureCheck {
            name = "workspace-basic";
            src = fixtureWorkspaceBasic;
            depsHash = "sha256-7t46ZAfJERoP/gCEIyqubbo3Ob3RLHW6NTDr1a5nnCw=";
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
            depsHash = "sha256-gIL4zhfAcMT3U0PIUAO4bBQk0EBXiGs0quYO3zm1DXU=";
            checkCommand = ''
              test -d node_modules
              node packages/beta/index.js | grep -qx "hello from alpha"
            '';
          };

          pnpm-tsc-check = mkPnpmFixtureCheck {
            name = "tsc-check";
            src = fixtureTscCheck;
            depsHash = "sha256-7t46ZAfJERoP/gCEIyqubbo3Ob3RLHW6NTDr1a5nnCw=";
            checkCommand = ''
              test -d node_modules
              node_modules/.bin/tsc --noEmit --lib ES2020,DOM packages/app/index.ts
            '';
          };

          pnpm-vitest-check = mkPnpmFixtureCheck {
            name = "vitest-check";
            src = fixtureVitestCheck;
            depsHash = "sha256-VgoszjnpdXC3uhzjGWIjv7W6BQgT8uldbSkgHu8S4RI=";
            checkCommand = ''
              test -d node_modules
              node_modules/.bin/vitest run --root packages/lib
            '';
          };

          pnpm-node-modules-output-layout = mkPnpmFixtureCheck {
            name = "node-modules-output-layout";
            src = fixtureWorkspaceBasic;
            depsHash = "sha256-7t46ZAfJERoP/gCEIyqubbo3Ob3RLHW6NTDr1a5nnCw=";
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
            depsHash = "sha256-R0X9msP0FeYEOnoO5rDwpykuj7FgWqEM8cGvZHwrvOc=";
            checkCommand = ''
              test -d node_modules
              node packages/app/index.js | grep -qx "pass"
            '';
          };

          # Mirrors nodejs.nix:125-129 installPhase; keep in sync.
          pnpm-nonhoisted-output-layout = mkPnpmFixtureCheck {
            name = "nonhoisted-output-layout";
            src = fixtureNonhoistedDep;
            depsHash = "sha256-R0X9msP0FeYEOnoO5rDwpykuj7FgWqEM8cGvZHwrvOc=";
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
          };
        };

        # Combined set of fixture-style tests (justfile parser validation, module
        # recipe patterns, and pnpm integration fixtures). Each value is a derivation;
        # the keys preserve the old check names for debugging via `passthru`.
        fixtureTests =
          lib.mapAttrs' (name: test: lib.nameValuePair "justfile-${name}" test) justfileValidationTests
          // lib.mapAttrs' (name: test: lib.nameValuePair "module-${name}" test) moduleJustfileTests
          // pnpmFixtureChecks;

        # A single aggregate check that depends on every fixture test, collapsing what
        # used to be ~32 individual CI checks into one. Building this forces all
        # sub-derivations to build; any failure fails the aggregate. Individual tests
        # remain reachable for debugging, e.g.
        #   nix build .#checks.<system>.fixture-tests.justfile-testSingleRecipe
        fixtureTestsCheck = pkgs.runCommand "fixture-tests" {passthru = fixtureTests;} ''
          echo "Aggregated fixture tests (justfile + module + pnpm):"
          ${lib.concatMapStringsSep "\n" (name: "echo '  ✅ ${name}: ${fixtureTests.${name}}'") (builtins.attrNames fixtureTests)}
          touch "$out"
        '';
      in {
        # Make jackLib and platformFilteredPackages available for devShell
        _module.args.jackpkgs =
          {
            lib = jackLib;
            modules = import ./modules;
            homeManagerModules = import ./modules/home-manager;
            darwinModules = import ./modules/nix-darwin;
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
            just = import ./tests/just.nix {
              inherit inputs lib;
            };
            lint-recipe = import ./tests/lint-recipe.nix {
              inherit inputs lib;
            };
            recipe-testing = import ./tests/test-recipe.nix {
              inherit inputs lib;
            };
            pkgs = import ./tests/pkgs.nix {
              inherit inputs lib;
            };
            pulumi = import ./tests/pulumi.nix {
              inherit inputs lib;
            };
            container = import ./tests/container.nix {
              inherit inputs lib;
            };
            python-package-fixes = import ./tests/python-package-fixes.nix {
              inherit lib;
            };
            python-workspace-paths = import ./tests/python-workspace-paths.nix {
              inherit lib;
            };
            helm-chart = import ./tests/helm-chart.nix {
              inherit lib pkgs;
            };
          };
        };

        # All justfile, module, and pnpm fixture tests collapse into one CI check.
        # See `fixtureTests` / `fixtureTestsCheck` above for the aggregation.
        checks = {
          fixture-tests = fixtureTestsCheck;
        };
      };

      flake = {
        # Expose overlays for backward compatibility
        overlays.default = import ./overlay.nix inputs;

        # Expose nix-darwin modules
        darwinModules.imessage-bridge = import ./modules/nix-darwin/imessage-bridge.nix;

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
