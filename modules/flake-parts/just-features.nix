# Shared declaration point for `just` recipes contributed by jackpkgs modules
# that do NOT own the just-flake import.
#
# Why this exists. A module that wants to register a `just` recipe must assign
# `just-flake.features.<name>`, an option it does not declare. The obvious fix
# -- import `just-flake.flakeModule` alongside the assignment, so the module is
# usable a la carte -- is wrong: that module arrives as a *value* through
# `jackpkgsInputs`, and a consumer flake whose module tree reaches jackpkgs
# along more than one route ends up holding two non-identical copies of it. The
# module system dedupes imports by identity, two distinct values are not
# identical, and evaluation then dies with
#
#   The option `perSystem.<system>.just-flake' ... is already declared
#
# which took out `nix develop` entirely in jmmaloney4/garden.
#
# So: contributors set `jackpkgs.justFeatures.<name>` here, and `just.nix` --
# the single module that legitimately owns the just-flake import -- merges them
# into `just-flake.features`. One importer of the foreign module, one writer of
# the foreign option, and a contributor that depends on neither.
#
# This file is imported BY PATH from both `just.nix` and `lean-recipes.nix`.
# Path-valued imports dedupe on path equality no matter how many times the
# enclosing module is instantiated -- precisely the property the value-valued
# import lacked.
{
  lib,
  flake-parts-lib,
  ...
}: {
  options.perSystem = flake-parts-lib.mkPerSystemOption ({...}: {
    options.jackpkgs.justFeatures = lib.mkOption {
      type = lib.types.attrsOf lib.types.raw;
      default = {};
      description = ''
        just-flake feature definitions contributed by jackpkgs modules other
        than `just.nix`, keyed by feature name. Each value is a just-flake
        feature attrset (`{enable, justfile}`).

        `just.nix` merges these into `just-flake.features`. When
        `flakeModules.just` is not imported nothing consumes them, so a module
        can register a recipe without requiring just-flake to be present --
        importing `flakeModules.lean` on its own evaluates cleanly and simply
        contributes no recipe.
      '';
    };
  });
}
