# Vendored Lean toolchain manifest — generated, do not hand-edit.
#
#     just lean-toolchain-fetch 4.34.0
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
  tag = "v4.34.0";
  rev = "293d5d0c0c3f3dded4688b3ccd6a33939ac5102b";
  toolchain = {
    aarch64-linux = {
      url = "https://github.com/leanprover/lean4/releases/download/v4.34.0/lean-4.34.0-linux_aarch64.tar.zst";
      hash = "sha256-QLBP23+4SdPIDhDDu+68e3NUttPwdFC5FowhSbQNKoI=";
    };
    x86_64-linux = {
      url = "https://github.com/leanprover/lean4/releases/download/v4.34.0/lean-4.34.0-linux.tar.zst";
      hash = "sha256-yqqYNWCYyF3A/LvSjh7GbznrZVGCmXK3Uv8g4ShrZGs=";
    };
    x86_64-darwin = {
      url = "https://github.com/leanprover/lean4/releases/download/v4.34.0/lean-4.34.0-darwin.tar.zst";
      hash = "sha256-6Qr+hMCiqjWD8+zQjlH7fu67hNNvmbfKxdPAZ/qGQLA=";
    };
    aarch64-darwin = {
      url = "https://github.com/leanprover/lean4/releases/download/v4.34.0/lean-4.34.0-darwin_aarch64.tar.zst";
      hash = "sha256-afJj+m4hu8JGa7+xr/zZJHnuJxTIg6B95UjgmaWSKTI=";
    };
  };
  # Same provenance upstream's own v4.33.1 manifest uses for these three.
  inherit (import "${upstream}/v4.19.0.nix") overlay;
  inherit (import "${upstream}/v4.27.0.nix") buildLeanPackage;
  inherit (import "${upstream}/v4.32.0.nix") bootstrap;
}
