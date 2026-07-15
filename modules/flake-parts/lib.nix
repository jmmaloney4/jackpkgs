# Module that provides jackpkgs.lib as a per-system option and
# preserves the legacy _module.args.jackpkgsLib for nodejs helpers.
#
# The per-system lib is the correct way to access jackpkgs lib helpers
# (e.g. mkIsolatedUvEnvFactory) because it uses the per-system pkgs.
# The flake-level flake.lib (flake.outputs.lib) hardcodes pkgs to the
# first entry in the systems list (aarch64-darwin) for back-compat and
# causes platform mismatches on other systems.
{jackpkgsInputs}: {lib, ...}: {
  options = let
    inherit (jackpkgsInputs.flake-parts.lib) mkDeferredModuleOption;
  in {
    perSystem = mkDeferredModuleOption ({pkgs, ...}: {
      options.jackpkgs.lib = lib.mkOption {
        type = lib.types.raw;
        default = import ../../lib {inherit pkgs;};
        defaultText = lib.literalExpression "import ./lib { inherit pkgs; }";
        description = ''
          Per-system jackpkgs lib with pkgs for the current system.
          Use this instead of flake.outputs.lib (which hardcodes
          aarch64-darwin) when building derivations.

          Example:

            mkIsolatedUvEnv = config.jackpkgs.lib.python.mkIsolatedUvEnvFactory {
              inherit (inputs) uv2nix pyproject-nix pyproject-build-systems;
            };
        '';
      };
    });
  };

  config = {
    _module.args.jackpkgsLib = import ../../lib/nodejs-helpers.nix {inherit lib;};
  };
}
