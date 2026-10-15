# Instantiates a Home Manager configuration with EVERY jackpkgs Home Manager
# module enabled and its required options wired: the check that the
# value-level nix-unit tests (tests/home-modules.nix) cannot make -- that the
# full activation package evaluates (no undeclared option, no missing package,
# no failed assertion).
#
# Same shape as tests/nixos-modules-instantiate.nix: the forced drvPath is
# interpolated into the check derivation (context discarded, so nothing is
# built), which makes an evaluation failure *be* a failed `nix flake check`.
{
  inputs,
  lib,
  pkgs,
}: let
  common = import ./home-modules-common.nix {inherit inputs lib;};

  # `tod` is an upstream-namespace module (`programs.tod`) whose package comes
  # from the jackpkgs overlay, which plain nixpkgs here lacks; it predates this
  # suite and is not exercised. The rest are `jackpkgs.<name>`.
  jackpkgsNames = lib.filter (n: n != "tod") (builtins.attrNames common.named);

  # build-user is a different account's profile (its own git identity), so it
  # is instantiated separately from the operator-style set.
  operatorNames = lib.filter (n: n != "build-user") jackpkgsNames;

  hm = common.eval [
    {
      jackpkgs = lib.genAttrs operatorNames (_: {enable = true;});
    }
    {
      jackpkgs.git =
        {
          signing.key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItest test";
          signing.program = "/usr/bin/true";
        }
        // common.identity;
      jackpkgs.cargo.buildJobs = 2;
      jackpkgs.shell.localSshAgentSocket = ".1password/agent.sock";
    }
  ];

  hmBuildUser = common.eval [{jackpkgs.build-user.enable = true;}];

  missingEnable =
    lib.filter (n: !(hm.options.jackpkgs.${n} ? enable)) jackpkgsNames;

  drvPaths = map (c: builtins.unsafeDiscardStringContext c.activationPackage.drvPath) [hm hmBuildUser];
in {
  all-enabled = assert lib.assertMsg (missingEnable == [])
  "jackpkgs Home Manager modules without an enable option: ${toString missingEnable}";
    pkgs.runCommand "home-modules-all-enabled" {} ''
      echo 'jackpkgs Home Manager modules (${toString (builtins.attrNames common.named)}) instantiate:'
      echo '${toString drvPaths}'
      touch "$out"
    '';
}
