# nix-unit tests for the shared NixOS module set (modules/nixos, modules/common;
# ADR-050, garden#2074 Part B PR 2).
#
# What these pin, beyond "it evaluates":
#
#   * The ADR-050 Decision 4 contract: identity/topology options have no
#     default, so enabling a module without wiring them FAILS at eval — and
#     importing the module without enabling it does not.
#   * Every refusal (assertion) path, not just the happy paths.
#   * The garden `mkIf … // {settings = …}` regression in ssh.nix, where the
#     sshd hardening was silently dropped.
#
# Value-level only: full system instantiation is the separate
# `nixos-modules-instantiate` check (tests/nixos-modules-instantiate.nix).
{
  inputs,
  lib,
}: let
  common = import ./nixos-modules-common.nix {inherit inputs lib;};
  inherit (common) eval failedAssertions named;

  cfgOf = modules: (eval modules).config;
in {
  # ---------------------------------------------------------------------
  # Inert import
  # ---------------------------------------------------------------------

  testDefaultImportIsInert = {
    expr = let
      c = cfgOf [];
    in {
      openssh = c.services.openssh.enable;
      tailscale = c.services.tailscale.enable;
      docker = c.virtualisation.docker.enable;
      failed = failedAssertions c;
    };
    expected = {
      openssh = false;
      tailscale = false;
      docker = false;
      failed = [];
    };
  };

  # Importing `default` and a named output together must not double-declare
  # options: both are paths, so the module system dedups them.
  testDefaultPlusNamedDedups = {
    expr =
      (cfgOf [
        named.ssh
        named.nix
      ]).jackpkgs.ssh.enable;
    expected = false;
  };

  # ---------------------------------------------------------------------
  # Named outputs stand alone (each declares its own dependencies)
  # ---------------------------------------------------------------------

  testNamedNixStandsAlone = {
    expr =
      lib.unique
      (inputs.nixpkgs.lib.nixosSystem {
        modules = [
          common.base
          named.nix
          {
            jackpkgs.user = {
              enable = true;
              username = "alice";
            };
            jackpkgs.nix.enable = true;
          }
        ];
      }).config.nix.settings.trusted-users;
    expected = ["root" "alice"];
  };

  testNamedDockerStandsAlone = {
    expr =
      (inputs.nixpkgs.lib.nixosSystem {
        modules = [
          common.base
          named.docker
          {
            jackpkgs.user = {
              enable = true;
              username = "alice";
            };
            jackpkgs.docker.enable = true;
          }
        ];
      }).config.users.groups.docker.members;
    expected = ["alice"];
  };

  # ---------------------------------------------------------------------
  # jackpkgs.user / jackpkgs.nix
  # ---------------------------------------------------------------------

  testNixTrustedUsersWithoutOperator = {
    expr = lib.unique (cfgOf [{jackpkgs.nix.enable = true;}]).nix.settings.trusted-users;
    expected = ["root"];
  };

  testUsernameRequiredWhenEnabled = {
    expr =
      (cfgOf [
        {
          jackpkgs.user.enable = true;
          jackpkgs.nix.enable = true;
        }
      ]).nix.settings.trusted-users;
    expectedError.type = "ThrownError";
    expectedError.msg = "jackpkgs\\.user\\.username";
  };

  testNixSubstitutersOptIn = {
    expr = let
      without = cfgOf [{jackpkgs.nix.enable = true;}];
      with' = cfgOf [
        {
          jackpkgs.nix.enable = true;
          jackpkgs.nix.substituters.enable = true;
        }
      ];
    in {
      without = builtins.elem "https://nix-community.cachix.org" without.nix.settings.substituters;
      with' = builtins.elem "https://nix-community.cachix.org" with'.nix.settings.substituters;
    };
    expected = {
      without = false;
      with' = true;
    };
  };

  # ---------------------------------------------------------------------
  # jackpkgs.ssh
  # ---------------------------------------------------------------------

  # Regression: garden wrote `mkIf c {enable = true;} // {settings = …;}`,
  # merging `settings` into the mkIf wrapper where it was ignored.
  testSshHardeningIsApplied = {
    expr = let
      s = (cfgOf [{jackpkgs.ssh.enable = true;}]).services.openssh.settings;
    in {
      inherit (s) PasswordAuthentication PermitRootLogin AllowAgentForwarding;
    };
    expected = {
      PasswordAuthentication = false;
      PermitRootLogin = "prohibit-password";
      AllowAgentForwarding = true;
    };
  };

  testSshKeysFanOut = {
    expr = let
      c = cfgOf [
        {
          jackpkgs.ssh = {
            enable = true;
            authorizedKeys = ["ssh-ed25519 AAAA test"];
            authorizedKeysUsers = ["root" "alice"];
          };
          users.users.alice.isNormalUser = true;
        }
      ];
    in {
      root = c.users.users.root.openssh.authorizedKeys.keys;
      alice = c.users.users.alice.openssh.authorizedKeys.keys;
    };
    expected = {
      root = ["ssh-ed25519 AAAA test"];
      alice = ["ssh-ed25519 AAAA test"];
    };
  };

  testSshKeysRequiredWhenFannedOut = {
    expr =
      (cfgOf [
        {
          jackpkgs.ssh = {
            enable = true;
            authorizedKeysUsers = ["root"];
          };
        }
      ]).users.users.root.openssh.authorizedKeys.keys;
    expectedError.type = "ThrownError";
    expectedError.msg = "jackpkgs\\.ssh\\.authorizedKeys";
  };

  # `[]` is not a way to satisfy the requirement.
  testSshEmptyKeyListRefused = {
    expr =
      (cfgOf [
        {
          jackpkgs.ssh = {
            enable = true;
            authorizedKeys = [];
            authorizedKeysUsers = ["root"];
          };
        }
      ]).users.users.root.openssh.authorizedKeys.keys;
    expectedError.type = "ThrownError";
    expectedError.msg = "jackpkgs\\.ssh\\.authorizedKeys";
  };

  # Garden's fan-out ran even with ssh disabled; here it is gated.
  testSshFanOutGatedOnEnable = {
    expr =
      (cfgOf [
        {
          jackpkgs.ssh.authorizedKeysUsers = ["root"];
        }
      ]).users.users.root.openssh.authorizedKeys.keys;
    expected = [];
  };

  # ---------------------------------------------------------------------
  # jackpkgs.attic
  # ---------------------------------------------------------------------

  testAtticSubstitutersAppendedAfterPublic = {
    expr = let
      s =
        (cfgOf [
          {
            jackpkgs.nix = {
              enable = true;
              substituters.enable = true;
            };
            jackpkgs.attic = {
              enable = true;
              endpoint = "https://attic.example.ts.net";
              pullCaches.c1 = "c1:KEY=";
              priority = 10;
            };
          }
        ]).nix.settings;
    in {
      last = lib.last s.substituters;
      first = builtins.head s.substituters;
      key = builtins.elem "c1:KEY=" s.trusted-public-keys;
    };
    expected = {
      last = "https://attic.example.ts.net/c1?priority=10";
      first = "https://cache.nixos.org";
      key = true;
    };
  };

  testAtticEndpointRequired = {
    expr =
      (cfgOf [
        {
          jackpkgs.attic = {
            enable = true;
            pullCaches.c1 = "c1:KEY=";
          };
        }
      ]).nix.settings.substituters;
    expectedError.type = "ThrownError";
    expectedError.msg = "jackpkgs\\.attic\\.endpoint";
  };

  # pullCaches is attrsOf-shaped; left unwired it must fail, not silently
  # become `{}` (zero caches).
  testAtticPullCachesRequired = {
    expr =
      (cfgOf [
        {
          jackpkgs.attic = {
            enable = true;
            endpoint = "https://attic.example.ts.net";
          };
        }
      ]).nix.settings.substituters;
    expectedError.type = "ThrownError";
    expectedError.msg = "jackpkgs\\.attic\\.pullCaches";
  };

  testAtticEmptyPullCachesRefused = {
    expr =
      (cfgOf [
        {
          jackpkgs.attic = {
            enable = true;
            endpoint = "https://attic.example.ts.net";
            pullCaches = {};
          };
        }
      ]).nix.settings.substituters;
    expectedError.type = "ThrownError";
    expectedError.msg = "jackpkgs\\.attic\\.pullCaches";
  };

  testAtticEndpointTrailingSlashRefused = {
    expr =
      (cfgOf [
        {
          jackpkgs.attic = {
            enable = true;
            endpoint = "https://attic.example.ts.net/";
            pullCaches.c1 = "c1:KEY=";
          };
        }
      ]).nix.settings.substituters;
    expectedError.type = "ThrownError";
    expectedError.msg = "jackpkgs\\.attic\\.endpoint";
  };

  # ---------------------------------------------------------------------
  # jackpkgs.zsh
  # ---------------------------------------------------------------------

  testZshSecretEnvExport = {
    expr = let
      c = cfgOf [
        {
          jackpkgs.zsh = {
            enable = true;
            secretEnv.MY_TOKEN = "/run/agenix/my-token";
          };
        }
      ];
    in
      lib.hasInfix ''export MY_TOKEN="$(</run/agenix/my-token)"'' c.environment.shellInit;
    expected = true;
  };

  testZshNoSecretBoundByDefault = {
    expr = lib.hasInfix "export" (cfgOf [{jackpkgs.zsh.enable = true;}]).environment.shellInit;
    expected = false;
  };

  testZshBadEnvNameRefused = {
    expr = failedAssertions (cfgOf [
      {
        jackpkgs.zsh = {
          enable = true;
          secretEnv."BAD-NAME" = "/run/agenix/x";
        };
      }
    ]);
    expected = ["jackpkgs.zsh.secretEnv: not valid environment variable names: BAD-NAME"];
  };

  testZshSecretEnvWithoutEnableRefused = {
    expr = failedAssertions (cfgOf [
      {
        jackpkgs.zsh.secretEnv.MY_TOKEN = "/run/agenix/my-token";
      }
    ]);
    expected = ["jackpkgs.zsh.secretEnv is set but jackpkgs.zsh.enable is not; the variables would never be exported."];
  };

  testZshSecretEnvRelativePathRefused = {
    expr =
      (cfgOf [
        {
          jackpkgs.zsh = {
            enable = true;
            secretEnv.MY_TOKEN = "relative/token";
          };
        }
      ]).environment.shellInit;
    expectedError.type = "ThrownError";
    expectedError.msg = "jackpkgs\\.zsh\\.secretEnv";
  };

  # ---------------------------------------------------------------------
  # jackpkgs.tailscale
  # ---------------------------------------------------------------------

  testTailscaleMullvadUnits = {
    expr = let
      c = cfgOf [
        {
          jackpkgs.tailscale = {
            enable = true;
            mullvad = {
              enable = true;
              exitNode = "us-chi-wg-301.mullvad.ts.net";
              exemptSourceCIDRs = ["10.42.0.0/16"];
            };
          };
        }
      ];
    in {
      daemon = c.services.tailscale.enable;
      units = builtins.all (n: c.systemd.services ? ${n}) [
        "tailscale-mullvad-exemptions"
        "tailscale-mullvad-exit-node"
      ];
      failed = failedAssertions c;
    };
    expected = {
      daemon = true;
      units = true;
      failed = [];
    };
  };

  testTailscaleNoMullvadUnitsByDefault = {
    expr = (cfgOf [{jackpkgs.tailscale.enable = true;}]).systemd.services ? tailscale-mullvad-exit-node;
    expected = false;
  };

  testTailscaleExitNodeRequired = {
    expr =
      (cfgOf [
        {
          jackpkgs.tailscale = {
            enable = true;
            mullvad.enable = true;
          };
        }
      ]).systemd.services.tailscale-mullvad-exit-node.serviceConfig.ExecStart;
    expectedError.type = "ThrownError";
    expectedError.msg = "jackpkgs\\.tailscale\\.mullvad\\.exitNode";
  };

  # ---------------------------------------------------------------------
  # jackpkgs.nixbuild / disks / zenith
  # ---------------------------------------------------------------------

  # environment.etc.<name>.text is types.lines: consumer builders append.
  testNixbuildMachinesMergeWithConsumerBuilders = {
    expr = let
      text =
        (cfgOf [
          {
            jackpkgs.nixbuild.enable = true;
            environment.etc."nix/machines".text = "ssh://builder.example x86_64-linux";
          }
        ]).environment.etc."nix/machines".text;
    in {
      nixbuild = lib.hasInfix "ssh://eu.nixbuild.net x86_64-linux" text;
      consumer = lib.hasInfix "ssh://builder.example x86_64-linux" text;
    };
    expected = {
      nixbuild = true;
      consumer = true;
    };
  };

  testDisksDefaults = {
    expr = let
      fs = (cfgOf [{jackpkgs.disks.enable = true;}]).fileSystems;
    in {
      root = fs."/".label;
      boot = fs."/boot".fsType;
    };
    expected = {
      root = "nixos";
      boot = "vfat";
    };
  };

  testZenithWrapper = {
    expr = (cfgOf [{jackpkgs.zenith.enable = true;}]).security.wrappers.zenith.capabilities;
    expected = "cap_sys_ptrace,cap_dac_read_search=ep";
  };
}
