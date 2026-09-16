# Vendored Lean toolchain manifest — generated, do not hand-edit.
#
#     just lean-toolchain-fetch 4.34.0-rc2
#
# Upstream lean4-nix cuts manifests per stable release; this version is one it
# does not carry, and manifests are what supply BINARY toolchains. Without one,
# lean4-nix source-builds the Lean compiler on top of Mathlib. See ADR-049.
#
# Unlike upstream's manifests this is a FUNCTION: upstream inherits `overlay`,
# `buildLeanPackage` and `bootstrap` from sibling files by relative path, which
# a copy living outside that directory cannot resolve. Taking the upstream
# manifests directory as an argument makes those references explicit.
{upstream}: {
  tag = "v4.34.0-rc2";
  rev = "6a10ac8c22beadecabdbb0919c2b50214762f91d";
  toolchain = {
    aarch64-linux = {
      url = "https://github.com/leanprover/lean4/releases/download/v4.34.0-rc2/lean-4.34.0-rc2-linux_aarch64.tar.zst";
      hash = "sha256-ZLQdtsFYFj5TpA/5UM3JePOJLLERKKTuBQ5N6OhyGJQ=";
    };
    x86_64-linux = {
      url = "https://github.com/leanprover/lean4/releases/download/v4.34.0-rc2/lean-4.34.0-rc2-linux.tar.zst";
      hash = "sha256-PQEQQSA6ys8wDTQ6OWc/fSM3Qzl5k3l8lBNGrp5d8ag=";
    };
    x86_64-darwin = {
      url = "https://github.com/leanprover/lean4/releases/download/v4.34.0-rc2/lean-4.34.0-rc2-darwin.tar.zst";
      hash = "sha256-0FWFkLsmGh2jp4LffUidu76PukhBu4f4cVQdIfL5ENE=";
    };
    aarch64-darwin = {
      url = "https://github.com/leanprover/lean4/releases/download/v4.34.0-rc2/lean-4.34.0-rc2-darwin_aarch64.tar.zst";
      hash = "sha256-ynmpKhXFbQJw2c26k2oHkz79FKfeY1tVsJgBl5znOQk=";
    };
  };
  # Same provenance upstream's own v4.33.1 manifest uses for these three.
  inherit (import "${upstream}/v4.19.0.nix") overlay;
  inherit (import "${upstream}/v4.27.0.nix") buildLeanPackage;
  inherit (import "${upstream}/v4.32.0.nix") bootstrap;
}
