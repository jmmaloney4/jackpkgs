# `just lean-toolchain-fetch <version>` — vendor a Lean toolchain manifest.
#
# jackpkgs.lean (lib/lean.nix `resolveManifestPath`/`loadManifest`,
# modules/flake-parts/lean.nix) resolves a `lean-toolchain` version to a
# binary-toolchain manifest, preferring one vendored at
# pkgs/lean4-toolchains/ over upstream lean4-nix's own. This recipe is what
# produces those vendored files: it drives lean4-nix's own generator, wraps
# the fragment it prints on stdout into the FUNCTION shape this repo's
# vendored manifests use (see any pkgs/lean4-toolchains/*.nix for the target
# shape), sanity-checks the result, and formats it with alejandra.
#
# Split into its own file rather than added to modules/flake-parts/lean.nix:
# at the time this was written lean.nix and lib/lean.nix were being edited
# concurrently elsewhere. Fold this module's `perSystem` into lean.nix's own
# (or add it to the `imports` list there) whenever that stops being true —
# nothing about the split is otherwise load-bearing.
#
# NOT gated behind `jackpkgs.lean.enable`. That flag governs whether a
# CONSUMER flake wants Lean environments built; this recipe instead
# maintains THIS repo's own pkgs/lean4-toolchains/ directory —
# `resolveManifestPath`'s `vendoredDir` is `../../pkgs/lean4-toolchains`
# relative to modules/flake-parts/lean.nix, i.e. always a path inside
# jackpkgs' own checkout, regardless of which flake imports the module. A
# downstream consumer running this recipe in their own repo would write a
# file their own module resolution never looks at, so the only checkout
# where running it does anything useful is jackpkgs' own — and jackpkgs
# dogfoods this module (modules/flake-parts/all.nix) WITHOUT ever setting
# jackpkgs.lean.enable = true, so gating on that flag would make the recipe
# unreachable in the one place it is meant to run.
{jackpkgsInputs}: {
  # just-flake's flake module defines `just-flake.features`, which the recipe
  # below declares. Importing it here rather than relying on the caller is what
  # makes `flakeModules.lean` usable a la carte: without it, a consumer that
  # imports only `flakeModules.{pkgs,lean}` fails to evaluate with
  # `The option `perSystem.<system>.just-flake' does not exist`.
  #
  # Importing it twice -- here and in modules/flake-parts/just.nix, both of
  # which reach `all.nix` -- is safe; the module system dedupes by identity.
  imports = [jackpkgsInputs.just-flake.flakeModule];

  perSystem = {
    pkgs,
    lib,
    ...
  }: let
    justfileHelpers = import ../../lib/justfile-helpers.nix {inherit lib;};
    inherit (justfileHelpers) mkRecipeWithParams;

    leanToolchainFetchRecipe =
      mkRecipeWithParams "lean-toolchain-fetch" [''version'']
      "Vendor a Lean toolchain manifest into pkgs/lean4-toolchains/ (pass the version WITHOUT a leading v, e.g. 4.34.0)"
      [
        "#!/usr/bin/env bash"
        "set -euo pipefail"
        ""
        "version=\"{{version}}\""
        ""
        "if [ -z \"$version\" ]; then"
        "  echo \"usage: just lean-toolchain-fetch <version-without-v>  (e.g. 4.34.0)\" >&2"
        "  exit 1"
        "fi"
        ""
        "if [[ \"$version\" == v* || \"$version\" == V* ]]; then"
        "  echo \"error: pass the version WITHOUT a leading v -- got \\\"$version\\\".\" >&2"
        "  echo \"lean4-nix#toolchain-fetch prepends v itself; passing a v-prefixed\" >&2"
        "  echo \"version silently produces 404ing download URLs for every platform.\" >&2"
        "  echo \"Try: just lean-toolchain-fetch \${version#v}\" >&2"
        "  exit 1"
        "fi"
        ""
        "tag=\"v$version\""
        "out=\"pkgs/lean4-toolchains/$tag.nix\""
        ""
        "echo \"==> fetching manifest fragment for $tag via the pinned lean4-nix\" >&2"
        "echo \"==> this downloads four platform tarballs and can take 10+ minutes\" >&2"
        "fragment=\"$(nix run ${jackpkgsInputs.lean4-nix}#toolchain-fetch -- \"$version\")\""
        ""
        "hash_count=\"$(printf '%s\\n' \"$fragment\" | grep -c 'hash = ' || true)\""
        "if [ \"$hash_count\" != \"4\" ]; then"
        "  echo \"error: expected 4 'hash = ' lines (one per platform), got $hash_count.\" >&2"
        "  echo \"Generator output looked truncated or malformed:\" >&2"
        "  echo \"$fragment\" >&2"
        "  exit 1"
        "fi"
        ""
        "if ! printf '%s\\n' \"$fragment\" | grep -qE 'rev = \"[^\"]+\"'; then"
        "  echo \"error: no non-empty rev = \\\"...\\\"; in generator output:\" >&2"
        "  echo \"$fragment\" >&2"
        "  exit 1"
        "fi"
        ""
        "if ! printf '%s\\n' \"$fragment\" | grep -qF \"tag = \\\"$tag\\\";\"; then"
        "  echo \"error: expected tag = \\\"$tag\\\"; in generator output, got:\" >&2"
        "  echo \"$fragment\" >&2"
        "  exit 1"
        "fi"
        ""
        "mkdir -p \"$(dirname \"$out\")\""
        ""
        "{"
        "  echo '# Vendored Lean toolchain manifest -- generated, do not hand-edit.'"
        "  echo '#'"
        "  echo \"#     just lean-toolchain-fetch $version\""
        "  echo '#'"
        "  echo '# Upstream lean4-nix cuts manifests per stable release; this version is one it'"
        "  echo '# does not carry, and manifests are what supply BINARY toolchains. Without one,'"
        "  echo '# lean4-nix source-builds the Lean compiler on top of Mathlib. See ADR-049.'"
        "  echo '#'"
        "  echo '# Unlike upstream manifests this is a FUNCTION: upstream inherits overlay,'"
        "  echo '# buildLeanPackage and bootstrap from sibling files by relative path, which'"
        "  echo '# a copy living outside that directory cannot resolve. Taking the upstream'"
        "  echo '# manifests directory as an argument makes those references explicit.'"
        "  echo '{upstream}: {'"
        "  echo \"$fragment\""
        "  echo '  inherit (import \"\${upstream}/v4.19.0.nix\") overlay;'"
        "  echo '  inherit (import \"\${upstream}/v4.27.0.nix\") buildLeanPackage;'"
        "  echo '  inherit (import \"\${upstream}/v4.32.0.nix\") bootstrap;'"
        "  echo '}'"
        "} > \"$out\""
        ""
        "${lib.getExe pkgs.alejandra} \"$out\""
        "echo \"==> wrote $out\" >&2"
      ]
      false;
  in {
    just-flake.features.lean-toolchain-fetch = {
      enable = true;
      justfile = leanToolchainFetchRecipe;
    };
  };
}
