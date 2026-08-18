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
          biome = pkgs.callPackage ./pkgs/biome {};
          codex-proxy = pkgs.callPackage ./pkgs/codex-proxy {
            inherit (nvfetcherSources.codex-proxy) src version;
          };
          codex-proxy-rs = pkgs.callPackage ./pkgs/codex-proxy-rs {
            inherit (nvfetcherSources.codex-proxy-rs) src version;
          };
          dbn-cli = pkgs.callPackage ./pkgs/dbn-cli {
            inherit (nvfetcherSources.dbn-cli) src version;
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
          adr-conflict-check = pkgs.callPackage ./pkgs/adr-conflict-check {};
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
        # Behavioural tests for the Node workspace runtime: these execute the
        # generated linking script instead of asserting on its text.
        nodejsRuntimeTests = import ./tests/nodejs-runtime.nix {
          inherit lib pkgs;
        };

        # The capture + workspace-runtime helpers under test in the pnpm
        # fixture checks below (same import the modules consume as
        # jackpkgsLib, see modules/flake-parts/lib.nix).
        nodejsHelpers = import ./lib/nodejs-helpers.nix {inherit lib;};
        nodejsLibFull = import ./lib {inherit pkgs;};
        captureNodeModulesCli = nodejsLibFull.nodejs.mkCaptureNodeModulesCli;

        integrationFixturesRoot = ./tests/fixtures/integration;
        fixtureSimplePnpm = integrationFixturesRoot + "/simple-pnpm";
        fixtureWorkspaceBasic = integrationFixturesRoot + "/pnpm-workspace-basic";
        fixtureWorkspaceGlob = integrationFixturesRoot + "/pnpm-workspace-glob";
        fixtureTscCheck = integrationFixturesRoot + "/pnpm-tsc-check";
        fixtureVitestCheck = integrationFixturesRoot + "/pnpm-vitest-check";
        fixtureNonhoistedDep = integrationFixturesRoot + "/pnpm-workspace-nonhoisted-dep";

        # Run pnpm on nodejs-slim_latest instead of its default node runtime:
        # the nixpkgs build of nodejs_24 24.15.0 has broken worker_threads fd
        # tracking on aarch64-darwin — pnpm's install workers trigger
        # EXC_GUARD SIGKILL at worker exit, killing the deps FOD right after
        # `pnpm install` completes. nodejs 26 is unaffected.
        # Mirrors the workaround in modules/flake-parts/nodejs.nix (#301).
        # https://github.com/NixOS/nixpkgs/issues/525627
        safePnpm = pkgs.pnpm_11.override {
          nodejs-slim = pkgs.nodejs-slim_latest;
        };

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
                  fetcherVersion = 4;
                  pnpm = safePnpm;
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
                safePnpm
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
            depsHash = "sha256-cnrJCL+ZkGR2kcjSzFdOwmUExhX2F/JDtLzG/NwAiH4=";
            checkCommand = ''
              test -d node_modules
              node index.js | grep -qx "pass"
            '';
          };

          pnpm-workspace-basic-postinstall = mkPnpmFixtureCheck {
            name = "workspace-basic";
            src = fixtureWorkspaceBasic;
            depsHash = "sha256-B1iBXUev+REvZpPF2djpVc10Wvd4K5r/LdngvN8V29Q=";
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
            depsHash = "sha256-dIp6CNh1Kn4aqJWku1G/FUdn/u+epzhqlqwnAkB2uW0=";
            checkCommand = ''
              test -d node_modules
              node packages/beta/index.js | grep -qx "hello from alpha"
            '';
          };

          pnpm-tsc-check = mkPnpmFixtureCheck {
            name = "tsc-check";
            src = fixtureTscCheck;
            depsHash = "sha256-B1iBXUev+REvZpPF2djpVc10Wvd4K5r/LdngvN8V29Q=";
            checkCommand = ''
              test -d node_modules
              node_modules/.bin/tsc --noEmit --lib ES2020,DOM packages/app/index.ts
            '';
          };

          pnpm-vitest-check = mkPnpmFixtureCheck {
            name = "vitest-check";
            src = fixtureVitestCheck;
            depsHash = "sha256-ALh9yqJI0DhGsClMzl8oT7pL+IyU5EdLhDugqQL+S90=";
            checkCommand = ''
              test -d node_modules
              node_modules/.bin/vitest run --root packages/lib
            '';
          };

          pnpm-node-modules-output-layout = mkPnpmFixtureCheck {
            name = "node-modules-output-layout";
            src = fixtureWorkspaceBasic;
            depsHash = "sha256-B1iBXUev+REvZpPF2djpVc10Wvd4K5r/LdngvN8V29Q=";
            checkCommand = ''
              ${captureNodeModulesCli}/bin/capture-node-modules "$out"
              test -d "$out/node_modules"

              # Workspace links are stripped from the captured tree (ADR-047):
              # the .pnpm peer-resolution link that used to dangle (#160) and
              # the per-package workspace link that poisoned live checkouts.
              test ! -L "$out/node_modules/.pnpm/node_modules/@test/lib"
              test ! -L "$out/app/node_modules/@test/lib"

              # Nothing in the capture dangles — the invariant that lets the
              # noBrokenSymlinks fixup check stay enabled on nodeModules.
              test -z "$(find "$out" -xtype l -print -quit)"
            '';
          };

          pnpm-nonhoisted-runtime = mkPnpmFixtureCheck {
            name = "nonhoisted-runtime";
            src = fixtureNonhoistedDep;
            depsHash = "sha256-cnrJCL+ZkGR2kcjSzFdOwmUExhX2F/JDtLzG/NwAiH4=";
            checkCommand = ''
              test -d node_modules
              node packages/app/index.js | grep -qx "pass"
            '';
          };

          # Consumes the same capture script as nodejs.nix's installPhase
          # (jackpkgsLib.nodejs.captureNodeModules, ADR-047).
          pnpm-nonhoisted-output-layout = mkPnpmFixtureCheck {
            name = "nonhoisted-output-layout";
            src = fixtureNonhoistedDep;
            depsHash = "sha256-cnrJCL+ZkGR2kcjSzFdOwmUExhX2F/JDtLzG/NwAiH4=";
            checkCommand = ''
              ${captureNodeModulesCli}/bin/capture-node-modules "$out"

              test -d "$out/node_modules"
              test ! -e "$out/node_modules/is-odd"
              test -z "$(find "$out/node_modules/.pnpm" -path '*/node_modules/node_modules' -print -quit)"

              # Dependency-store links survive the ADR-047 strip: per-package
              # links resolve into the root .pnpm store.
              test -L "$out/packages/app/node_modules/is-odd"
              test -L "$out/packages/lib/node_modules/is-number"

              # The workspace link does not: in $out it resolves to
              # $out/packages/lib, a skeleton holding only a nested
              # node_modules copy — the exact link that sent Node's resolver
              # to a package with no sources (garden, 2026-08-10).
              test ! -L "$out/packages/app/node_modules/@test/lib"

              # And nothing in the capture dangles.
              test -z "$(find "$out" -xtype l -print -quit)"
            '';
          };

          # End-to-end regression test for the garden failure mode (ADR-047):
          # capture the tree the way nodejs.nix does, consume it the way
          # checks/pre-commit do (mkWorkspaceRuntime against a checkout whose
          # real pnpm install is gone), then require Node to resolve the
          # workspace: import. Before the strip, the captured per-package link
          # @test/lib resolved to the skeleton directory and Node failed with
          # ERR_MODULE_NOT_FOUND before ever reaching the correct root-level
          # workspace symlink.
          pnpm-captured-workspace-runtime = mkPnpmFixtureCheck {
            name = "captured-workspace-runtime";
            src = fixtureNonhoistedDep;
            depsHash = "sha256-cnrJCL+ZkGR2kcjSzFdOwmUExhX2F/JDtLzG/NwAiH4=";
            checkCommand = ''
              # Capture outside the source tree: nodejs.nix captures into a
              # store path, and a capture directory under $PWD would be seen by
              # the helper's own node_modules sweep of the checkout. The CLI
              # takes the output dir as an explicit argument rather than an
              # ambient $out, so no subshell is needed to keep this capture's
              # destination from clobbering the derivation's real $out.
              ${captureNodeModulesCli}/bin/capture-node-modules "$NIX_BUILD_TOP/captured"

              rm -rf node_modules packages/app/node_modules packages/lib/node_modules

              ${nodejsHelpers.nodejs.mkWorkspaceRuntime {
                nodeModules = "$NIX_BUILD_TOP/captured";
                workspaceRoot = fixtureNonhoistedDep;
                packages = ["packages/app" "packages/lib"];
              }}

              # The runtime linked package-local trees at the captured store…
              test -L packages/app/node_modules
              test -L packages/lib/node_modules
              # …which no longer carry the poisoned workspace link…
              test ! -e packages/app/node_modules/@test/lib
              # …so resolution goes through the root-level link to the live
              # tree, and both the workspace import and the per-package
              # external deps resolve.
              node packages/app/index.js | grep -qx "pass"
            '';
          };
        };

        # Combined set of fixture-style tests (justfile parser validation, module
        # recipe patterns, Node workspace runtime behaviour, and pnpm integration
        # fixtures). Each value is a derivation;
        # the keys preserve the old check names for debugging via `passthru`.
        fixtureTests =
          lib.mapAttrs' (name: test: lib.nameValuePair "justfile-${name}" test) justfileValidationTests
          // lib.mapAttrs' (name: test: lib.nameValuePair "module-${name}" test) moduleJustfileTests
          // lib.mapAttrs' (name: test: lib.nameValuePair "nodejs-runtime-${name}" test) nodejsRuntimeTests
          // pnpmFixtureChecks;

        # A single aggregate check that depends on every fixture test, collapsing what
        # used to be ~32 individual CI checks into one. Building this forces all
        # sub-derivations to build; any failure fails the aggregate. Individual tests
        # remain reachable for debugging, e.g.
        #   nix build .#checks.<system>.fixture-tests.justfile-testSingleRecipe
        fixtureTestsCheck = pkgs.runCommand "fixture-tests" {passthru = fixtureTests;} ''
          echo "Aggregated fixture tests (justfile + module + nodejs-runtime + pnpm):"
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

        jackpkgs.pre-commit.adr.enable = false;

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
            python-group-spec = import ./tests/python-group-spec.nix {
              inherit lib;
            };
            python-namespace-check = import ./tests/python-namespace-check.nix {
              inherit lib;
            };
            python-isolated-env = import ./tests/python-isolated-env.nix {
              inherit lib pkgs inputs;
            };
            python-extra-workspaces = import ./tests/python-extra-workspaces.nix {
              inherit lib pkgs inputs;
            };
            lsp = import ./tests/lsp.nix {
              inherit lib inputs;
            };
            helm-chart = import ./tests/helm-chart.nix {
              inherit lib pkgs;
            };
            fmt = import ./tests/fmt.nix {
              inherit inputs lib;
            };
          };
        };

        # All justfile, module, nodejs-runtime, and pnpm fixture tests collapse into
        # one CI check.
        # See `fixtureTests` / `fixtureTestsCheck` above for the aggregation.
        checks =
          {
            fixture-tests = fixtureTestsCheck;
          }
          # ADR script-behaviour tests stay as individual checks.
          // lib.mapAttrs' (name: drv: lib.nameValuePair "adr-${name}" drv) (
            import ./tests/adr.nix {
              inherit pkgs;
              adr-conflict-check = allPackages.adr-conflict-check;
            }
          )
          # mdformat `$`-escaping behaviour, pinned because MyST dollarmath
          # downstream depends on it and nothing else covers it (#361).
          // lib.mapAttrs' (name: drv: lib.nameValuePair "mdformat-${name}" drv) (
            import ./tests/mdformat-escaping.nix {
              inherit pkgs;
              mdformatFormatter = config.treefmt.settings.formatter.mdformat;
            }
          );
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
