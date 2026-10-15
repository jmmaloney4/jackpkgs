# NixOS module aggregator (ADR-051), exposed as
# `inputs.jackpkgs.nixosModules.default`. Imports every module in ./modules.nix;
# consumers wanting a narrow slice import `nixosModules.<name>` instead.
#
# A function of the flake `inputs` (applied in flake.nix) because the named set
# includes the input-backed glue (`agenix`, `determinate`).
#
# Importing is inert: every module is gated on its own `jackpkgs.<name>.enable`
# (default false), and required identity/topology options are only read once
# the module that needs them is enabled. That includes `determinate`, whose
# upstream module is otherwise on by default (see ./determinate.nix).
inputs: {
  imports = builtins.attrValues (import ./modules.nix inputs);
}
