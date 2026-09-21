# NixOS module aggregator (ADR-050).
#
# Exposed as `inputs.jackpkgs.nixosModules.default`; consumers wanting a
# narrow slice import named outputs instead. The shared fleet module set
# (promoted from garden's nixfiles/, garden#2074 Part B) lands here in the
# follow-up PRs recorded in ADR-050's implementation plan — PR 2 brings the
# common/NixOS set, so today this aggregator is intentionally empty.
{
  imports = [
    # ./agenix.nix            # PR 2 (shape gated by ADR-050 OD-C)
    # ./disks.nix             # PR 2
    # ./docker.nix            # PR 2
    # ./security-wrappers.nix # PR 2
    # ./tailscale.nix         # PR 2
  ];
}
