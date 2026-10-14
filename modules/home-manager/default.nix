# Home Manager module aggregator (ADR-051), exposed as
# `inputs.jackpkgs.homeModules.default`. Imports every module in ./modules.nix;
# consumers wanting a narrow slice import `homeModules.<name>` instead.
#
# Importing is inert. Required identity options (`jackpkgs.git.userName`, ...)
# are only read once the module that needs them is enabled.
#
# No specialArgs contract: nothing here reads `inputs` or `hostname`. (Garden's
# own home modules do; the NixOS/nix-darwin `jackpkgs.operator` module supplies
# them to the modules a consumer adds -- see modules/common/operator.nix.)
{
  imports = builtins.attrValues (import ./modules.nix);
}
