# The named Home Manager module set (ADR-051 Decision 1): output name -> module
# file. The single source of truth for both `flake.homeModules.<name>` and the
# `default` aggregator (./default.nix), so a module cannot be exported by name
# and silently missing from `default`, or vice versa.
#
# Each file is gated on its own `jackpkgs.<name>.enable` (`programs.tod.enable`
# for the one upstream-namespace module), so importing is inert.
{
  build-user = ./build-user.nix;
  cargo = ./cargo.nix;
  git = ./git.nix;
  jujutsu = ./jujutsu.nix;
  shell = ./shell.nix;
  tod = ./programs/tod.nix;
}
