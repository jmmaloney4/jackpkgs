# The named NixOS module set (ADR-050 Decision 1): output name -> module file.
#
# The single source of truth for both `flake.nixosModules.<name>` and the
# `default` aggregator (./default.nix), so a module cannot be exported by
# name and silently missing from `default`, or vice versa.
#
# Each file declares its own cross-module dependencies through `imports`
# (e.g. nix.nix and docker.nix import common/user.nix for the operator
# account), so every named output evaluates on its own. Where a concern has a
# NixOS-only half, the name points at that half, which imports the
# platform-agnostic file from ../common.
{
  attic = ../common/attic.nix;
  disks = ./disks.nix;
  docker = ./docker.nix;
  fonts = ../common/fonts.nix;
  gnupg-agent = ../common/gnupg-agent.nix;
  nix = ./nix.nix;
  nixbuild = ../common/nixbuild.nix;
  packages = ../common/packages.nix;
  ssh = ../common/ssh.nix;
  tailscale = ./tailscale.nix;
  user = ../common/user.nix;
  zenith = ./zenith.nix;
  zsh = ../common/zsh.nix;
}
