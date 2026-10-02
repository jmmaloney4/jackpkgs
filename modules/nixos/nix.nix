# NixOS half of jackpkgs.nix: nix daemon housekeeping whose options exist
# only on NixOS. The option surface (`jackpkgs.nix.*`) and the cross-platform
# settings live in ../common/nix.nix.
#
# Promoted from the inline module in garden `nixfiles/modules/nixos/default.nix`.
# Its `determinate.enable = true` line is not here: it needs the
# determinate-nix NixOS module, which arrives with the cheap-input glue
# (`determinate-nix`/`agenix` flake inputs, ADR-050 Decision 3).
{
  config,
  lib,
  ...
}: {
  imports = [../common/nix.nix];

  config = lib.mkIf config.jackpkgs.nix.enable {
    nix.gc.automatic = true;
    nix.nrBuildUsers = 16;
    nix.optimise.automatic = true;
  };
}
