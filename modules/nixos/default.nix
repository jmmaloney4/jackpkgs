# NixOS module aggregator (ADR-050), exposed as
# `inputs.jackpkgs.nixosModules.default`. Imports every module in ./modules.nix;
# consumers wanting a narrow slice import `nixosModules.<name>` instead.
#
# Importing is inert: every module is gated on its own `jackpkgs.<name>.enable`
# (default false), and required identity/topology options are only read once
# the module that needs them is enabled.
#
# Not here yet (ADR-050 implementation plan): the cheap-input glue
# (`agenix`, `determinate-nix`) and the profiles/home-manager tree (PR 3).
{
  imports = builtins.attrValues (import ./modules.nix);
}
