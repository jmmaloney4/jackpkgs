# OPT-IN acceptance harness for the Mathlib branch of `jackpkgs.lean` (ADR-052).
#
# Not wired into `checks`: the fixed-output derivation is ~6.8 GB and needs the
# network, so it belongs on a machine with a persistent store. Use it to mint a
# hash, to prove the FOD is reproducible, and to prove Lake accepts it.
#
#   # 1. Mint (build fails and prints the real hash):
#   nix build --impure -L --expr \
#     'let f = builtins.getFlake (toString ./.); in
#      (import ./tests/lean-mathlib.nix {
#        inputs = f.inputs // { self = f; }; pkgs = f.inputs.nixpkgs.legacyPackages.${builtins.currentSystem};
#        lib = f.inputs.nixpkgs.lib; system = builtins.currentSystem;
#        src = /path/to/lean/project; }).deps'
#
#   # 2. Reproducible? (set artifactHash, then rebuild from scratch and compare)
#   nix build --rebuild ...   # same expression with artifactHash = "sha256-..."
#
#   # 3. Accepted by Lake: build `.build`, and `.rejectsSorry` must also succeed.
{
  inputs,
  lib,
  pkgs,
  system,
  src,
  artifactHash ? null,
}: let
  leanModule = import ../modules/flake-parts/lean.nix {jackpkgsInputs = inputs;};
  evaluated = inputs.flake-parts.lib.evalFlakeModule {inherit inputs;} {
    systems = [system];
    imports = [inputs.just-flake.flakeModule leanModule];
    jackpkgs.lean.enable = true;
    perSystem = _: {
      jackpkgs.lean.projects.mathlibproj = {inherit src artifactHash;};
    };
  };
  cfg = evaluated.config.perSystem system;
  build = cfg.packages.mathlibproj-lean;
in {
  deps = cfg.packages.mathlibproj-lean-deps;
  inherit build;
  devShell = cfg.devShells.mathlibproj;

  # Negative control against the real Mathlib closure: a `sorry` must fail under
  # the flags the package uses, and pass without them (so the flag is what is
  # being tested).
  rejectsSorry =
    pkgs.runCommand "lean-mathlib-rejects-sorry" {
      nativeBuildInputs = [build.passthru.toolchain];
    } ''
      export HOME="$TMPDIR"
      cp -R ${src}/. "$TMPDIR/p" && chmod -R u+w "$TMPDIR/p" && cd "$TMPDIR/p"
      mkdir -p Spike && printf 'import Mathlib.Data.Nat.Basic\ntheorem bad : (1 : Nat) = 2 := sorry\n' > Spike/Bad.lean
      printf '\n[[lean_lib]]\nname = "Spike"\n' >> lakefile.toml
      if lake --packages=${build.passthru.overridesJson} build --no-ansi --wfail Spike; then
        echo "lake build --wfail accepted a sorry" >&2; exit 1
      fi
      lake --packages=${build.passthru.overridesJson} build --no-ansi Spike
      touch "$out"
    '';
}
