# End-to-end checks for `jackpkgs.lean` against a real Lean checkout.
#
# tests/lean.nix covers the pure helpers in lib/lean.nix; nothing there builds
# a toolchain or a dependency, so every claim the module makes about ARTIFACTS
# — that the tag resolves to a binary Lean, that dependencies come out where
# `LEAN_PATH` says they do — was untested until this file. Those are exactly
# the claims that fail silently: a wrong `LEAN_PATH` entry is an empty
# directory, not an error, and the module would keep evaluating green.
#
# The fixture is deliberately Mathlib-FREE, which selects the source-build
# branch (`lake2nix.buildDeps`). That is the branch CI can afford: the Mathlib
# branch is a fixed-output derivation over `lake exe cache get`, ~6.8 GB, and
# belongs in a machine with a persistent store rather than in every
# `nix flake check`. See ADR-049 and #392.
#
# It is also pinned to v4.34.0 on purpose. Upstream lean4-nix ships manifests
# only up to v4.33.1, so v4.34.0 resolves to jackpkgs' own
# pkgs/lean4-toolchains/v4.34.0.nix — which is a FUNCTION, not an attrset.
# That is `loadManifest`'s vendored branch plus `resolveManifestPath`'s
# vendored-wins precedence, neither of which any upstream tag reaches.
{
  inputs,
  lib,
  pkgs,
  system,
}: let
  flakeParts = inputs.flake-parts.lib;

  # The module under test, instantiated the way a consumer flake would.
  # `just-flake`'s flake module comes along because lean.nix imports
  # lean-recipes.nix, which registers a `just` recipe.
  leanModule = import ../modules/flake-parts/lean.nix {jackpkgsInputs = inputs;};

  fixture = ./fixtures/lean/project;

  evaluated = flakeParts.evalFlakeModule {inherit inputs;} {
    systems = [system];
    imports = [inputs.just-flake.flakeModule leanModule];
    jackpkgs.lean.enable = true;
    perSystem = _: {
      jackpkgs.lean.projects.leanfixture.src = fixture;
    };
  };

  perSystemConfig = evaluated.config.perSystem system;

  deps = perSystemConfig.packages."leanfixture-lean-deps";
  devShell = perSystemConfig.devShells.leanfixture;

  # The dependency name is read out of the committed manifest rather than
  # restated, so repinning the fixture cannot leave these checks asserting
  # about a package it no longer has.
  depNames =
    map (p: p.name)
    (builtins.fromJSON (builtins.readFile "${toString fixture}/lake-manifest.json")).packages;

  # `LEAN_PATH` is only set on the shell when the module believes it has
  # dependencies. Its absence is the Mathlib-without-a-hash shape, which this
  # fixture must never reach — catching that here rather than as an
  # `unknown module prefix` several minutes into a build.
  leanPath =
    devShell.LEAN_PATH
    or (throw "jackpkgs.lean fixture: devShell has no LEAN_PATH, so the module took the no-deps path");
in
  assert lib.assertMsg (depNames != []) ''
    tests/fixtures/lean/project has an empty lake-manifest.json. An empty
    dependency set exercises neither branch of the module.
  '';
  assert lib.assertMsg (!(builtins.elem "mathlib" depNames)) ''
    tests/fixtures/lean/project depends on mathlib, which selects the 6.8 GB
    fixed-output branch. This fixture exists to keep that out of CI.
  ''; {
    # Does the source-build branch put artifacts where the module's
    # `leanPathEntries` claims? Verified against a built output, because the
    # layout is upstream lean4-nix's (`rsync` of the source plus a copy of
    # `.lake`), not something jackpkgs controls — and Lake moved `.olean`
    # output from `.lake/build/lib` to `.lake/build/lib/lean` in a past
    # release, so this is a real moving target.
    deps = pkgs.runCommand "lean-project-deps" {} (''
        set -euo pipefail
      ''
      + lib.concatMapStrings (n: ''
        echo "checking dependency ${n}"
        test -d ${deps}/packages/${n}/.lake/build/lib/lean \
          || { echo "missing ${n}/.lake/build/lib/lean in ${deps}" >&2; exit 1; }
        test -n "$(find ${deps}/packages/${n}/.lake/build/lib/lean -name '*.olean' -print -quit)" \
          || { echo "no .olean under ${n}/.lake/build/lib/lean" >&2; exit 1; }
      '')
      depNames
      + ''
        touch "$out"
      '');

    # The actual contract: the environment the module hands a developer can
    # compile the project against its Nix-built dependencies. The fixture's
    # own source names a `batteries`-only declaration, so this fails with
    # `unknown module prefix` if `LEAN_PATH` is wrong — verified by control,
    # the same file does exactly that with `LEAN_PATH` unset.
    #
    # The check runs on the devShell's OWN inputs and env rather than
    # re-deriving a toolchain, so it tests what a developer would enter.
    env =
      pkgs.runCommand "lean-project-env" {
        inherit (devShell) nativeBuildInputs;
        LEAN_PATH = leanPath;

        # The shell itself, so regenerating the fixture's lake-manifest.json
        # does not need a second way to get a v4.34.0 toolchain:
        #
        #   nix develop --impure \
        #     .#checks.<system>.lean-project-env.passthru.devShell
        #
        # See tests/fixtures/lean/project/lakefile.toml.
        passthru = {inherit devShell;};
      } ''
        set -euo pipefail
        export HOME="$TMPDIR"

        # The whole point of the vendored manifest: a binary Lean at the tag
        # the checkout pins, not whatever lean4-nix happens to ship.
        lean --version
        lean --version | grep -q 'version 4.34.0' \
          || { echo "toolchain is not v4.34.0" >&2; exit 1; }

        cp -R ${fixture}/. "$TMPDIR/project"
        chmod -R u+w "$TMPDIR/project"
        cd "$TMPDIR/project"

        mkdir -p "$TMPDIR/out"
        lean -o "$TMPDIR/out/Basic.olean" LeanFixture/Basic.lean
        test -s "$TMPDIR/out/Basic.olean" \
          || { echo "lean produced no olean" >&2; exit 1; }

        touch "$out"
      '';
  }
