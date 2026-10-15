# The platform-agnostic module set (ADR-051 Decision 1 and Decision 5 as
# amended by the 2026-10 darwin-export note): output name -> module file.
#
# Single source of truth for the common/ modules' exports. Both
# `flake.nixosModules.<name>` (via ../nixos/modules.nix) and
# `flake.darwinModules.<name>` (flake.nix) are built from this set, so a
# module cannot be exported on one platform and silently dropped on the other.
#
# Every file here is written to evaluate on NixOS and nix-darwin: platform
# differences are guarded inside the module (`pkgs.stdenv.hostPlatform.isDarwin`,
# `options ? <path>`), never by the consumer. NixOS-only halves (disks, docker,
# zenith, and the NetworkManager patch in nixos/tailscale.nix) are not in this
# set; ../nixos/modules.nix layers them on top (and points `profile` at its
# NixOS half, which adds the Home Manager NixOS module and the locale).
{
  attic = ./attic.nix;
  build-user = ./build-user.nix;
  fonts = ./fonts.nix;
  gnupg-agent = ./gnupg-agent.nix;
  guest-user = ./guest-user.nix;
  nix = ./nix.nix;
  nixbuild = ./nixbuild.nix;
  operator = ./operator.nix;
  packages = ./packages.nix;
  profile = ./profile.nix;
  ssh = ./ssh.nix;
  tailscale = ./tailscale.nix;
  user = ./user.nix;
  zsh = ./zsh.nix;
}
