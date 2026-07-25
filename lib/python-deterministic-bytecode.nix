# Overlay for pyproject-nix build sets: make installed Python bytecode
# bit-reproducible (jackpkgs#355).
#
# pyproject-nix's pyprojectInstallHook installs wheels via uv with
# UV_COMPILE_BYTECODE=1, which produces timestamp-invalidated .pyc files
# whose marshalled contents additionally depend on the build's random
# PYTHONHASHSEED (frozenset constant ordering). The resulting package
# outputs are not bit-reproducible across builders, which poisons binary
# caches with divergent realizations of the same store path and breaks
# nix2container image pushes (recorded layer digests never match a store
# holding the "other" realization).
#
# This overlay swaps the scope's pyprojectInstallHook for a wrapper that
# propagates the original hook and registers a postFixup that recompiles
# all bytecode deterministically (PYTHONHASHSEED=0, PEP 552 unchecked-hash
# invalidation). pyprojectHook and pyprojectWheelHook resolve their install
# hook through the scope, so both sdist and wheel builds pick this up.
{lib}: final: prev: let
  pythonOnBuild = final.python.pythonOnBuildForHost or final.python.pythonForBuild;
in {
  pyprojectInstallHook = final.pkgs.makeSetupHook {
    name = "jackpkgs-deterministic-bytecode-install-hook";
    propagatedBuildInputs = [prev.pyprojectInstallHook];
    substitutions = {
      pythonInterpreter = pythonOnBuild.interpreter;
      pythonSitePackages = final.python.sitePackages;
    };
  } ./deterministic-bytecode-hook.sh;
}
