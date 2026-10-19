# Instantiates a NixOS system with EVERY jackpkgs NixOS module enabled and
# its required options wired — the check that the value-level nix-unit tests
# (tests/nixos-modules.nix) cannot make: that the full system derivation
# evaluates (no undeclared option, no missing package, no failed assertion,
# which `system.build.toplevel` enforces).
#
# Same shape as tests/overlays.nix: the forced drvPath is interpolated into the
# check derivation (context discarded, so nothing is built), which makes an
# evaluation failure *be* a failed `nix flake check`.
{
  inputs,
  lib,
  pkgs,
}: let
  common = import ./nixos-modules-common.nix {inherit inputs lib;};

  enabledNames = builtins.attrNames common.named;

  system = common.eval [
    {
      # Every module in the named set, enabled — a newly added module that
      # isn't wired here fails the assertion below instead of going untested.
      jackpkgs = lib.genAttrs enabledNames (_: {enable = true;});
    }
    {
      jackpkgs.user.username = "alice";
      jackpkgs.operator.home.modules = [
        {
          home.stateVersion = "26.05";
          jackpkgs.git = {
            enable = true;
            userName = "Alice Example";
            userEmail = "alice@example.com";
          };
          jackpkgs.shell.enable = true;
        }
      ];
      jackpkgs.cache-target-pruner.user = "alice";
      jackpkgs.build-user.username = "builder";
      jackpkgs.guest-user = {
        username = "carol";
        uid = 1002;
        authorizedKeys = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIcarol carol"];
      };
      jackpkgs.nix.substituters.enable = true;
      jackpkgs.ssh = {
        authorizedKeys = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItest test"];
        authorizedKeysUsers = ["root" "alice"];
      };
      jackpkgs.attic = {
        endpoint = "https://attic.example.ts.net";
        pullCaches.c1 = "c1:KEY=";
      };
      jackpkgs.tailscale.mullvad = {
        enable = true;
        exitNode = "us-chi-wg-301.mullvad.ts.net";
        exemptSourceCIDRs = ["10.42.0.0/16"];
      };
      jackpkgs.repo-sync = {
        user = "alice";
        repo = "example-org/example-repo";
        repoPath = "/home/alice/checkout";
        branch = "agent-sync";
        paths = ["notes"];
        flattenSkillsDir = "notes";
        commitAuthor = {
          name = "Sync Bot";
          email = "sync-bot@example.com";
        };
      };
      jackpkgs.zsh.secretEnv.MY_TOKEN = "/run/agenix/my-token";
      # Exercises the agenix glue end to end (secret -> activation script).
      age.secrets.my-token.file = builtins.toFile "my-token.age" "placeholder";
    }
  ];

  # `jackpkgs.<name>.enable` must exist for every named output — the ADR-051
  # Decision 2 "every module has an enable flag" rule, checked mechanically.
  missingEnable =
    lib.filter (n: !(system.options.jackpkgs.${n} ? enable)) enabledNames;

  drvPath = builtins.unsafeDiscardStringContext system.config.system.build.toplevel.drvPath;
in {
  all-enabled = assert lib.assertMsg (missingEnable == [])
  "jackpkgs NixOS modules without an enable option: ${toString missingEnable}";
    pkgs.runCommand "nixos-modules-all-enabled" {} ''
      echo 'jackpkgs NixOS modules (${toString enabledNames}) instantiate:'
      echo '${drvPath}'
      touch "$out"
    '';
}
