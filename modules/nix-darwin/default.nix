# nix-darwin module aggregator (ADR-051), exposed as
# `inputs.jackpkgs.darwinModules.default`. Imports `imessage-bridge` plus every
# platform-agnostic module in ../common/modules.nix; consumers wanting a narrow
# slice import `darwinModules.<name>` instead.
#
# Importing is inert: every module is gated on its own `jackpkgs.<name>.enable`
# (default false). The common/ set is NOT validated against a real nix-darwin
# evaluation (jackpkgs has no nix-darwin input); see tests/darwin-modules.nix
# for what is checked.
{
  imports =
    [./imessage-bridge.nix]
    ++ builtins.attrValues (import ../common/modules.nix);
}
