# Recompile installed Python bytecode deterministically (jackpkgs#355).
#
# uv (invoked by pyproject-install-hook with UV_COMPILE_BYTECODE=1) compiles
# bytecode with timestamp invalidation and inherits the build sandbox's
# random PYTHONHASHSEED. Marshalled code objects that contain frozenset
# constants serialize in hash order, so two builds of the same derivation can
# produce different .pyc bytes (observed: google-cloud-bigquery's
# query.cpython-314.pyc differing wholesale between builders). Divergent
# realizations of the same store path across machines break consumers that
# assume path == bytes — most acutely nix2container image pushes, which
# record layer tar digests at build time and re-tar the local store at push.
#
# Fix: drop whatever bytecode the installer produced and recompile with
#   - PYTHONHASHSEED=0: stable marshal output for hash-ordered constants
#   - --invalidation-mode unchecked-hash (PEP 552): pyc headers carry a
#     source hash instead of a timestamp, and the runtime skips source
#     validation on import — correct for immutable store paths.
#
# Runs from postFixupHooks so it re-compiles after fixups (e.g. patchShebangs)
# have finished rewriting any .py sources.
echo "Sourcing jackpkgs-deterministic-bytecode-hook"

jackpkgsDeterministicBytecodePhase() {
  local sitePackages="${out:?}/@pythonSitePackages@"
  if [ -d "$sitePackages" ]; then
    echo "Recompiling Python bytecode deterministically in $sitePackages"
    find "$sitePackages" -type f -name '*.pyc' -delete
    # compileall exits non-zero if any file fails to compile (some packages
    # ship Python-2-only or template .py files). Those files simply end up
    # without bytecode, which the runtime handles; don't fail the build.
    PYTHONHASHSEED=0 @pythonInterpreter@ -m compileall \
      --invalidation-mode unchecked-hash \
      -q -f -j "${NIX_BUILD_CORES:-1}" "$sitePackages" || true
  fi
}

postFixupHooks+=(jackpkgsDeterministicBytecodePhase)
