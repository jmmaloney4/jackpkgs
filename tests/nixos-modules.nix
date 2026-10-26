# nix-unit tests for the shared NixOS module set (modules/nixos, modules/common;
# ADR-051, garden#2074 Part B PR 2).
#
# What these pin, beyond "it evaluates":
#
#   * The ADR-051 Decision 4 contract: identity/topology options have no
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

  profileWiring = {
    jackpkgs.profile.enable = true;
    jackpkgs.user.username = "alice";
    jackpkgs.ssh.authorizedKeys = ["ssh-ed25519 AAAA test"];
    jackpkgs.attic = {
      endpoint = "https://attic.example.ts.net";
      pullCaches.c1 = "c1:KEY=";
    };
  };

  operatorWiring = {
    jackpkgs.user.username = "alice";
    jackpkgs.operator = {
      enable = true;
      home.modules = [
        {
          home.stateVersion = "26.05";
          jackpkgs.git = {
            enable = true;
            userName = "Alice Example";
            userEmail = "alice@example.com";
          };
        }
      ];
    };
  };

  guestWiring = {
    jackpkgs.guest-user = {
      enable = true;
      username = "carol";
      uid = 1002;
      authorizedKeys = ["ssh-ed25519 AAAA carol"];
    };
  };

  # jackpkgs.repo-sync: the fully wired module, `extra` merged over it.
  repoSyncFull = {
    user = "alice";
    repo = "example-org/example-repo";
    repoPath = "/home/alice/checkout";
    branch = "agent-sync";
    paths = ["notes"];
    commitAuthor = {
      name = "Sync Bot";
      email = "sync-bot@example.com";
    };
  };
  repoSyncWiring = extra: {
    jackpkgs.repo-sync = lib.recursiveUpdate ({enable = true;} // repoSyncFull) extra;
  };
  # Wiring with the option at `path` left out; forces ExecStart.
  repoSyncMissing = path: msg: {
    expr = let
      pruned =
        if builtins.length path == 1
        then removeAttrs repoSyncFull path
        else repoSyncFull // {${builtins.head path} = removeAttrs repoSyncFull.${builtins.head path} [(builtins.elemAt path 1)];};
    in
      (cfgOf [{jackpkgs.repo-sync = {enable = true;} // pruned;}]).systemd.services.repo-sync.serviceConfig.ExecStart;
    expectedError.type = "ThrownError";
    expectedError.msg = msg;
  };
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
  # options: both are paths, so the module system dedups them. `eval` (via
  # `cfgOf`) already imports `default`, so the named outputs listed here are
  # the second import of the same files.
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

  # ---------------------------------------------------------------------
  # Closed silent no-ops / overridable defaults (PR #418 review)
  # ---------------------------------------------------------------------

  testSshSettingsOverridableWithoutMkForce = {
    expr = let
      c = cfgOf [
        {
          jackpkgs.ssh = {
            enable = true;
            authorizedKeys = ["ssh-ed25519 AAAA test"];
            authorizedKeysUsers = ["root"];
          };
          services.openssh.settings = {
            PermitRootLogin = "no";
            AllowAgentForwarding = false;
          };
        }
      ];
    in {
      root = c.services.openssh.settings.PermitRootLogin;
      fwd = c.services.openssh.settings.AllowAgentForwarding;
    };
    expected = {
      root = "no";
      fwd = false;
    };
  };

  testSshEnableWithoutUsersRefused = {
    expr = failedAssertions (cfgOf [
      {
        jackpkgs.ssh = {
          enable = true;
          authorizedKeys = ["ssh-ed25519 AAAA test"];
        };
      }
    ]);
    expected = ["jackpkgs.ssh.enable is set but jackpkgs.ssh.authorizedKeysUsers is empty: sshd would run with password auth off and no authorized keys (lockout)."];
  };

  testAtticBadCacheNameRefused = {
    expr = builtins.length (failedAssertions (cfgOf [
      {
        jackpkgs.attic = {
          enable = true;
          endpoint = "https://h.ts.net";
          pullCaches."a b" = "k:KEY=";
        };
      }
    ]));
    expected = 1;
  };

  testTailscaleMullvadWithoutTailscaleRefused = {
    expr = failedAssertions (cfgOf [
      {
        jackpkgs.tailscale.mullvad = {
          enable = true;
          exitNode = "x.mullvad.ts.net";
          exemptSourceCIDRs = ["10.42.0.0/16"];
        };
      }
    ]);
    expected = ["jackpkgs.tailscale.mullvad.enable requires jackpkgs.tailscale.enable; without it no units are produced."];
  };

  testTailscaleExemptCidrsRequired = {
    expr =
      (cfgOf [
        {
          jackpkgs.tailscale = {
            enable = true;
            mullvad = {
              enable = true;
              exitNode = "x.mullvad.ts.net";
            };
          };
        }
      ]).systemd.services.tailscale-mullvad-exemptions.serviceConfig.ExecStart;
    expectedError.type = "ThrownError";
    expectedError.msg = "jackpkgs\\.tailscale\\.mullvad\\.exemptSourceCIDRs";
  };

  # ---------------------------------------------------------------------
  # Input-backed glue: jackpkgs.agenix / jackpkgs.determinate
  # ---------------------------------------------------------------------

  # Upstream `determinate.enable` defaults to TRUE, so importing the upstream
  # module alone would swap nix.package on every host. Pin that importing the
  # jackpkgs aggregator does not (compared against a config with no jackpkgs
  # modules at all, so the check cannot pass vacuously).
  testDeterminateImportIsInert = {
    expr = let
      bare = (inputs.nixpkgs.lib.nixosSystem {modules = [common.base];}).config;
      c = cfgOf [];
    in {
      enable = c.determinate.enable;
      package = c.nix.package.drvPath == bare.nix.package.drvPath;
      registry = c.nix.registry ? nixpkgs == bare.nix.registry ? nixpkgs;
    };
    expected = {
      enable = false;
      package = true;
      registry = true;
    };
  };

  # Positive control for the test above: the same comparison DOES see the
  # swap when the module is enabled.
  testDeterminateEnableSwapsNixPackage = {
    expr = let
      bare = (inputs.nixpkgs.lib.nixosSystem {modules = [common.base];}).config;
      c = cfgOf [{jackpkgs.determinate.enable = true;}];
    in {
      enable = c.determinate.enable;
      swapped = c.nix.package.drvPath != bare.nix.package.drvPath;
    };
    expected = {
      enable = true;
      swapped = true;
    };
  };

  # A consumer can still override the upstream switch (mkDefault priority).
  testDeterminateConsumerCanOverride = {
    expr =
      (cfgOf [
        {
          jackpkgs.determinate.enable = true;
          determinate.enable = false;
        }
      ]).determinate.enable;
    expected = false;
  };

  testDeterminateStandsAlone = {
    expr =
      (inputs.nixpkgs.lib.nixosSystem {
        modules = [common.base named.determinate {jackpkgs.determinate.enable = true;}];
      }).config.determinate.enable;
    expected = true;
  };

  # `default` + `determinate`/`agenix` together must not double-declare the
  # upstream options (the glue carries a module `key`).
  testInputBackedGlueDedups = {
    expr = let
      c = cfgOf [named.agenix named.determinate];
    in {
      agenix = c.jackpkgs.agenix.enable;
      determinate = c.jackpkgs.determinate.enable;
    };
    expected = {
      agenix = false;
      determinate = false;
    };
  };

  testAgenixIdentityDefaultWhenEnabled = {
    expr = (cfgOf [{jackpkgs.agenix.enable = true;}]).age.identityPaths;
    expected = ["/etc/ssh/ssh_host_ed25519_key"];
  };

  # Disabled: the host-key opinion is not applied. Upstream's own default is
  # derived from services.openssh (empty when sshd is off), so `[]` here is
  # upstream's value, not ours; the enabled test above is the positive control.
  testAgenixIdentityNotForcedWhenDisabled = {
    expr = (cfgOf []).age.identityPaths;
    expected = [];
  };

  testAgenixIdentityOverridable = {
    expr =
      (cfgOf [
        {
          jackpkgs.agenix.enable = true;
          age.identityPaths = ["/var/lib/age/key"];
        }
      ]).age.identityPaths;
    expected = ["/var/lib/age/key"];
  };

  testAgenixStandsAlone = {
    expr =
      (inputs.nixpkgs.lib.nixosSystem {
        modules = [common.base named.agenix {jackpkgs.agenix.enable = true;}];
      }).config.age.identityPaths;
    expected = ["/etc/ssh/ssh_host_ed25519_key"];
  };

  # ---------------------------------------------------------------------
  # Profiles and accounts (garden#2074 Part B PR 3)
  # ---------------------------------------------------------------------

  testProfileEnablesBaseline = {
    expr = let
      c = cfgOf [profileWiring];
    in {
      nix = c.jackpkgs.nix.enable;
      substituters = c.jackpkgs.nix.substituters.enable;
      attic = c.jackpkgs.attic.enable;
      ssh = c.services.openssh.enable;
      sshUsers = c.jackpkgs.ssh.authorizedKeysUsers;
      tailscale = c.services.tailscale.enable;
      fonts = c.jackpkgs.fonts.enable;
      user = c.jackpkgs.user.enable;
      locale = c.i18n.defaultLocale;
      failed = failedAssertions c;
    };
    expected = {
      nix = true;
      substituters = true;
      attic = true;
      ssh = true;
      sshUsers = ["root"];
      tailscale = true;
      fonts = true;
      user = true;
      locale = "en_US.UTF-8";
      failed = [];
    };
  };

  testProfileDefaultsAreOptOutable = {
    expr = let
      c = cfgOf [
        profileWiring
        {jackpkgs.tailscale.enable = false;}
      ];
    in
      c.services.tailscale.enable;
    expected = false;
  };

  # The profile makes the operator and cache part of the host's contract: a
  # host on the profile that never named its operator fails, it does not come
  # up with an unnamed trusted-user.
  testProfileRequiresOperatorName = {
    expr =
      (cfgOf [
        {
          jackpkgs.profile.enable = true;
          jackpkgs.ssh.authorizedKeys = ["ssh-ed25519 AAAA test"];
          jackpkgs.attic = {
            endpoint = "https://attic.example.ts.net";
            pullCaches.c1 = "c1:KEY=";
          };
        }
      ]).nix.settings.trusted-users;
    expectedError.type = "ThrownError";
    expectedError.msg = "jackpkgs\\.user\\.username";
  };

  testProfileNamedOutputStandsAlone = {
    expr =
      (inputs.nixpkgs.lib.nixosSystem {
        modules = [
          common.base
          named.profile
          {
            jackpkgs.profile.enable = true;
            jackpkgs.user.username = "alice";
            jackpkgs.ssh.authorizedKeys = ["ssh-ed25519 AAAA test"];
            jackpkgs.attic = {
              endpoint = "https://attic.example.ts.net";
              pullCaches.c1 = "c1:KEY=";
            };
          }
        ];
      }).config.i18n.defaultLocale;
    expected = "en_US.UTF-8";
  };

  testProfileInertWhenDisabled = {
    expr = let
      c = cfgOf [];
    in {
      locale = c.i18n.defaultLocale;
      nix = c.jackpkgs.nix.enable;
    };
    expected = {
      locale = "en_US.UTF-8"; # NixOS' own default, not the profile's
      nix = false;
    };
  };

  testOperatorCreatesAccount = {
    expr = let
      c = (eval [named.profile operatorWiring]).config;
      u = c.users.users.alice;
    in {
      normal = u.isNormalUser;
      uid = u.uid;
      groups = u.extraGroups;
      sshUsers = c.jackpkgs.ssh.authorizedKeysUsers;
    };
    expected = {
      normal = true;
      uid = 1000;
      groups = ["networkmanager" "wheel"];
      sshUsers = ["alice"];
    };
  };

  # The consumer's Home Manager modules and jackpkgs' own homeModules both
  # reach the account: git is enabled by the consumer's module, whose options
  # come from jackpkgs' aggregator.
  testOperatorWiresHomeManager = {
    expr = let
      hm = (eval [named.profile operatorWiring]).config.home-manager.users.alice;
    in {
      git = hm.programs.git.enable;
      name = hm.programs.git.settings.user.name;
    };
    expected = {
      git = true;
      name = "Alice Example";
    };
  };

  # operator / build-user alone (no profile, no default aggregator) must
  # evaluate: they bring the Home Manager NixOS module themselves.
  testOperatorAloneEvaluates = {
    expr = let
      c =
        (inputs.nixpkgs.lib.nixosSystem {
          modules = [common.base named.operator operatorWiring];
        }).config;
    in
      c.home-manager.users ? alice;
    expected = true;
  };

  testBuildUserAloneEvaluates = {
    expr = let
      c =
        (inputs.nixpkgs.lib.nixosSystem {
          modules = [
            common.base
            named.build-user
            {
              jackpkgs.build-user = {
                enable = true;
                username = "builder";
              };
            }
          ];
        }).config;
    in
      c.home-manager.users ? builder;
    expected = true;
  };

  # uid is a default, not a fixed value: a host may give the operator another.
  testOperatorUidOverridable = {
    expr =
      (cfgOf [
        named.profile
        operatorWiring
        {users.users.alice.uid = 1001;}
      ]).users.users.alice.uid;
    expected = 1001;
  };

  testOperatorSuppliesHostnameSpecialArg = {
    expr = let
      c =
        (eval [
          named.profile
          operatorWiring
          {
            networking.hostName = "box";
            jackpkgs.operator.home.extraSpecialArgs.marker = "x";
          }
        ]).config;
    in {
      inherit (c.home-manager.extraSpecialArgs) hostname marker;
    };
    expected = {
      hostname = "box";
      marker = "x";
    };
  };

  testOperatorHostnameOverrideRefused = {
    expr = failedAssertions (cfgOf [
      named.profile
      operatorWiring
      {jackpkgs.operator.home.extraSpecialArgs.hostname = "other";}
    ]);
    expected = ["jackpkgs.operator.home.extraSpecialArgs must not define `hostname`: jackpkgs.operator supplies it from networking.hostName, and a second definition would silently win."];
  };

  testOperatorHomeModulesRequired = {
    expr =
      (cfgOf [
        named.profile
        {
          jackpkgs.user.username = "alice";
          jackpkgs.operator.enable = true;
        }
      ]).home-manager.users.alice.home.username;
    expectedError.type = "ThrownError";
    expectedError.msg = "jackpkgs\\.operator\\.home\\.modules";
  };

  testOperatorEmptyHomeModulesRefused = {
    expr =
      (cfgOf [
        named.profile
        {
          jackpkgs.user.username = "alice";
          jackpkgs.operator = {
            enable = true;
            home.modules = [];
          };
        }
      ]).home-manager.users.alice.home.username;
    expectedError.type = "ThrownError";
    expectedError.msg = "jackpkgs\\.operator\\.home\\.modules";
  };

  testOperatorUsernameRequired = {
    expr =
      (cfgOf [
        named.profile
        {
          jackpkgs.operator = {
            enable = true;
            home.modules = [{home.stateVersion = "26.05";}];
          };
        }
      ]).users.users;
    expectedError.type = "ThrownError";
    expectedError.msg = "jackpkgs\\.user\\.username";
  };

  testOperatorInertWhenDisabled = {
    expr = (cfgOf []).users.users ? alice;
    expected = false;
  };

  testBuildUser = {
    expr = let
      c =
        (eval [
          named.profile
          {
            jackpkgs.build-user = {
              enable = true;
              username = "builder";
            };
          }
        ]).config;
    in {
      groups = c.users.users.builder.extraGroups;
      sshUsers = c.jackpkgs.ssh.authorizedKeysUsers;
      home = c.home-manager.users.builder.programs.git.settings.user.email;
      stateVersion = c.home-manager.users.builder.home.stateVersion;
    };
    expected = {
      groups = [];
      sshUsers = ["root" "builder"];
      home = "build@localhost";
      stateVersion = "24.05";
    };
  };

  testBuildUserNameRequired = {
    expr = (cfgOf [named.profile {jackpkgs.build-user.enable = true;}]).users.users;
    expectedError.type = "ThrownError";
    expectedError.msg = "jackpkgs\\.build-user\\.username";
  };

  testGuestUser = {
    expr = let
      c = cfgOf [guestWiring];
      u = c.users.users.carol;
    in {
      uid = u.uid;
      keys = u.openssh.authorizedKeys.keys;
      groups = u.extraGroups;
      hm = c.home-manager.users or {};
      # Not in the operator fan-out: that would give her the operator's keys.
      sshUsers = c.jackpkgs.ssh.authorizedKeysUsers;
    };
    expected = {
      uid = 1002;
      keys = ["ssh-ed25519 AAAA carol"];
      groups = [];
      hm = {};
      sshUsers = [];
    };
  };

  testGuestUserKeysRequired = {
    expr =
      (cfgOf [
        {
          jackpkgs.guest-user = {
            enable = true;
            username = "carol";
            uid = 1002;
          };
        }
      ]).users.users.carol.openssh.authorizedKeys.keys;
    expectedError.type = "ThrownError";
    expectedError.msg = "jackpkgs\\.guest-user\\.authorizedKeys";
  };

  testGuestUserEmptyKeysRefused = {
    expr =
      (cfgOf [
        {
          jackpkgs.guest-user = {
            enable = true;
            username = "carol";
            uid = 1002;
            authorizedKeys = [];
          };
        }
      ]).users.users.carol.openssh.authorizedKeys.keys;
    expectedError.type = "ThrownError";
    expectedError.msg = "jackpkgs\\.guest-user\\.authorizedKeys";
  };

  testGuestUserUidRequired = {
    expr =
      (cfgOf [
        {
          jackpkgs.guest-user = {
            enable = true;
            username = "carol";
            authorizedKeys = ["ssh-ed25519 AAAA carol"];
          };
        }
      ]).users.users.carol.uid;
    expectedError.type = "ThrownError";
    expectedError.msg = "jackpkgs\\.guest-user\\.uid";
  };

  # macOS uids start at 501, so the type admits them; on Linux NixOS's own
  # isNormalUser assertion refuses the system-account range instead.
  testGuestUserLinuxSystemUidRefused = {
    expr = let
      e = eval [
        {
          jackpkgs.guest-user = {
            enable = true;
            username = "carol";
            uid = 501;
            authorizedKeys = ["ssh-ed25519 AAAA carol"];
          };
        }
      ];
    in
      map (a: a.message) (lib.filter (a: !a.assertion) e.config.assertions);
    expected = ["A user cannot have a users.users.carol.uid set below 1000 and set users.users.carol.isNormalUser.\nEither users.users.carol.isSystemUser must be set to true instead of users.users.carol.isNormalUser\nor users.users.carol.uid must be changed to 1000 or above.\n"];
  };

  # ---------------------------------------------------------------------
  # jackpkgs.cache-target-pruner
  # ---------------------------------------------------------------------

  testCacheTargetPrunerUnits = {
    expr = let
      c = cfgOf [
        {
          users.users.alice = {
            isNormalUser = true;
            home = "/home/alice";
          };
          jackpkgs.cache-target-pruner = {
            enable = true;
            user = "alice";
          };
        }
      ];
      svc = c.systemd.services.cache-target-pruner.serviceConfig;
    in {
      user = svc.User;
      type = svc.Type;
      # Scans the named user's cache dir, with the documented thresholds.
      args = lib.hasSuffix " ${lib.escapeShellArg "/home/alice/.cache"} ${lib.escapeShellArg "/"} 15 20 15 4" svc.ExecStart;
      timer = c.systemd.timers.cache-target-pruner.timerConfig.OnUnitActiveSec;
      failed = failedAssertions c;
    };
    expected = {
      user = "alice";
      type = "oneshot";
      args = true;
      timer = "900s";
      failed = [];
    };
  };

  testCacheTargetPrunerInertWhenDisabled = {
    expr = (cfgOf []).systemd.services ? cache-target-pruner;
    expected = false;
  };

  testCacheTargetPrunerUserRequired = {
    expr =
      (cfgOf [{jackpkgs.cache-target-pruner.enable = true;}]).systemd.services.cache-target-pruner.serviceConfig.User;
    expectedError.type = "ThrownError";
    expectedError.msg = "jackpkgs\\.cache-target-pruner\\.user";
  };

  # A user the system does not declare is refused by assertion, not by an
  # opaque missing-attribute error and not by silently scanning "/.cache".
  testCacheTargetPrunerUndeclaredUserRefused = {
    expr = failedAssertions (cfgOf [
      {
        jackpkgs.cache-target-pruner = {
          enable = true;
          user = "ghost";
        };
      }
    ]);
    expected = ["jackpkgs.cache-target-pruner.user = \"ghost\" is not declared in users.users; the pruner needs its home directory."];
  };

  # ---------------------------------------------------------------------
  # jackpkgs.repo-sync (NixOS-only; promoted from garden's services.garden-sync)
  # ---------------------------------------------------------------------

  testRepoSyncDefaultsOff = {
    expr = let
      c = cfgOf [];
    in {
      enable = c.jackpkgs.repo-sync.enable;
      service = c.systemd.services ? repo-sync;
      timer = c.systemd.timers ? repo-sync;
      failed = failedAssertions c;
    };
    expected = {
      enable = false;
      service = false;
      timer = false;
      failed = [];
    };
  };

  # Every identity/topology option is required (ADR-051 Decision 4): the
  # module encodes no repository, branch, checkout location or author. Each
  # case drops exactly one and forces the unit's ExecStart, which reads them all.
  testRepoSyncRequiredOptionUser = repoSyncMissing ["user"] "jackpkgs\\.repo-sync\\.user'";
  testRepoSyncRequiredOptionRepo = repoSyncMissing ["repo"] "jackpkgs\\.repo-sync\\.repo'";
  testRepoSyncRequiredOptionRepoPath = repoSyncMissing ["repoPath"] "jackpkgs\\.repo-sync\\.repoPath'";
  testRepoSyncRequiredOptionBranch = repoSyncMissing ["branch"] "jackpkgs\\.repo-sync\\.branch'";
  testRepoSyncRequiredOptionPaths = repoSyncMissing ["paths"] "jackpkgs\\.repo-sync\\.paths'";
  testRepoSyncRequiredOptionAuthorName = repoSyncMissing ["commitAuthor" "name"] "jackpkgs\\.repo-sync\\.commitAuthor\\.name'";
  testRepoSyncRequiredOptionAuthorEmail = repoSyncMissing ["commitAuthor" "email"] "jackpkgs\\.repo-sync\\.commitAuthor\\.email'";

  # `paths = []` would make "commit nothing" expressible; the type refuses it.
  testRepoSyncEmptyPathsRefused = {
    expr = (cfgOf [(repoSyncWiring {paths = [];})]).systemd.services.repo-sync.serviceConfig.User;
    expectedError.type = "ThrownError";
    expectedError.msg = "paths";
  };

  testRepoSyncRepoMustBeOwnerName = {
    expr = (cfgOf [(repoSyncWiring {repo = "https://github.com/o/r.git";})]).systemd.services.repo-sync.serviceConfig.User;
    expectedError.type = "ThrownError";
    expectedError.msg = "repo";
  };

  testRepoSyncUnitShape = {
    expr = let
      c = cfgOf [(repoSyncWiring {interval = 900;})];
      svc = c.systemd.services.repo-sync;
      tmr = c.systemd.timers.repo-sync;
    in {
      type = svc.serviceConfig.Type;
      user = svc.serviceConfig.User;
      timeout = svc.serviceConfig.TimeoutStartSec;
      execIsStorePath = lib.hasPrefix "/nix/store/" svc.serviceConfig.ExecStart;
      requiresNetwork = svc.wants == ["network-online.target"] && svc.after == ["network-online.target"];
      wantedBy = tmr.wantedBy;
      onBoot = tmr.timerConfig.OnBootSec;
      active = tmr.timerConfig.OnUnitActiveSec;
      failed = failedAssertions c;
    };
    expected = {
      type = "oneshot";
      user = "alice";
      timeout = "10m";
      execIsStorePath = true;
      requiresNetwork = true;
      wantedBy = ["timers.target"];
      onBoot = "5m";
      active = "900s";
      failed = [];
    };
  };

  # The script carries the consumer's values and none of garden's.
  testRepoSyncScriptUsesWiredValues = {
    expr = let
      t = (cfgOf [(repoSyncWiring {})]).jackpkgs.repo-sync.script.text;
      has = lib.hasInfix;
    in {
      repoUrl = has "https://github.com/example-org/example-repo.git" t;
      branch = has "branch=agent-sync" t;
      base = has "base=main" t;
      author = has "Sync Bot" t;
      paths = has "notes" t;
      bootstrapHint = has "git clone git@github.com:example-org/example-repo.git" t;
      noGarden = !(has "jmmaloney4" t) && !(has "garden" t) && !(has "hermes" t);
      noFlatten = !(has "sroot=" t);
    };
    expected = {
      repoUrl = true;
      branch = true;
      base = true;
      author = true;
      paths = true;
      bootstrapHint = true;
      noGarden = true;
      noFlatten = true;
    };
  };

  testRepoSyncFlattenOptIn = {
    expr = let
      t =
        (cfgOf [
          (repoSyncWiring {
            paths = ["skills"];
            flattenSkillsDir = "skills";
          })
        ]).jackpkgs.repo-sync.script.text;
    in
      lib.hasInfix "sroot=skills" t;
    expected = true;
  };

  testRepoSyncFlattenDirMustBeInPaths = {
    expr = failedAssertions (cfgOf [
      (repoSyncWiring {
        paths = ["notes"];
        flattenSkillsDir = "skills";
      })
    ]);
    expected = ["jackpkgs.repo-sync.flattenSkillsDir must be one of (or inside) `paths`; otherwise the moves would never be committed."];
  };

  testRepoSyncBranchMustDifferFromBase = {
    expr = failedAssertions (cfgOf [(repoSyncWiring {branch = "main";})]);
    expected = ["jackpkgs.repo-sync.branch must differ from baseBranch (main); the sync would rebase and PR a branch onto itself."];
  };

  testRepoSyncRefusesDotDotPaths = {
    expr = failedAssertions (cfgOf [(repoSyncWiring {paths = ["../escape"];})]);
    expected = ["jackpkgs.repo-sync.paths and flattenSkillsDir must not contain `..` components."];
  };

  testRepoSyncOnePasswordPairRefused = {
    expr = failedAssertions (cfgOf [(repoSyncWiring {onePassword.githubTokenRef = "op://v/i/f";})]);
    expected = ["jackpkgs.repo-sync.onePassword.tokenFile and githubTokenRef must be set together (or both null)."];
  };

  # Token source: configuring 1Password must not silently fall back (the
  # script exits non-zero instead), and the env-file fallback is opt-in.
  testRepoSyncTokenSources = {
    expr = let
      plain = (cfgOf [(repoSyncWiring {})]).jackpkgs.repo-sync.script.text;
      envf = (cfgOf [(repoSyncWiring {githubTokenEnvFile = "/home/alice/.agent/.env";})]).jackpkgs.repo-sync.script.text;
      op =
        (cfgOf [
          (repoSyncWiring {
            onePassword = {
              # Any package with a main program: the default is unfree.
              package = inputs.nixpkgs.legacyPackages.x86_64-linux.hello;
              tokenFile = "/run/agenix/op-token";
              githubTokenRef = "op://v/i/f";
            };
          })
        ]).jackpkgs.repo-sync.script.text;
    in {
      plainNoEnvFile = !(lib.hasInfix "grep -E '^GITHUB_TOKEN=" plain);
      envFile = lib.hasInfix "/home/alice/.agent/.env" envf;
      envFileStripsQuotes = lib.hasInfix "\${tok#\\\"}" envf && lib.hasInfix "\${tok#\\'}" envf;
      plainNoQuoteStrip = !(lib.hasInfix "tok#" plain);
      opFailsLoudly = lib.hasInfix "not falling back to other credentials" op;
      opNoGhFallback = !(lib.hasInfix "auth token" op);
    };
    expected = {
      plainNoEnvFile = true;
      envFile = true;
      envFileStripsQuotes = true;
      plainNoQuoteStrip = true;
      opFailsLoudly = true;
      opNoGhFallback = true;
    };
  };

  testRepoSyncNamedStandsAlone = {
    expr =
      (inputs.nixpkgs.lib.nixosSystem {
        modules = [
          common.base
          named.repo-sync
          (repoSyncWiring {})
        ];
      }).config.systemd.timers.repo-sync.wantedBy;
    expected = ["timers.target"];
  };

  # ---------------------------------------------------------------------
  # jackpkgs.claude-managed-settings
  # ---------------------------------------------------------------------

  testClaudeManagedSettingsInstallsEtcEntries = {
    expr = let
      c = cfgOf [{jackpkgs.claude-managed-settings.enable = true;}];
    in {
      files = builtins.attrNames (lib.filterAttrs (n: _: lib.hasPrefix "claude-code/" n) c.environment.etc);
      failed = failedAssertions c;
    };
    expected = {
      files = [
        "claude-code/hooks/message-timestamps"
        "claude-code/managed-settings.json"
        "claude-code/statusline-command.sh"
      ];
      failed = [];
    };
  };

  testClaudeManagedSettingsInertWhenDisabled = {
    expr = builtins.any (lib.hasPrefix "claude-code/") (builtins.attrNames (cfgOf []).environment.etc);
    expected = false;
  };

  # The shipped default is what seven consumes without wiring anything, so it
  # must itself be valid JSON that points at the paths the module installs.
  testClaudeManagedSettingsDefaultPayloadReferencesInstalledPaths = {
    expr = let
      j = builtins.fromJSON (builtins.readFile ../modules/nixos/claude-managed-settings/managed-settings.json);
    in {
      statusLine = j.statusLine.command;
      hasHooks = builtins.all (k: j.hooks ? ${k}) ["SessionStart" "UserPromptSubmit" "MessageDisplay"];
      # The shipped copy carries no host-specific allowlist entries.
      noAutoMode = !(j ? autoMode);
    };
    expected = {
      statusLine = "bash /etc/claude-code/statusline-command.sh";
      hasHooks = true;
      noAutoMode = true;
    };
  };

  # A consumer's own payload replaces the shipped default: the installed
  # derivation changes when `settingsFile` does (and only then).
  testClaudeManagedSettingsPayloadOverridable = {
    expr = let
      drv = mods: (cfgOf mods).environment.etc."claude-code/managed-settings.json".source.drvPath;
      on = {jackpkgs.claude-managed-settings.enable = true;};
      custom = {
        jackpkgs.claude-managed-settings.settingsFile = builtins.toFile "s.json" "{}";
      };
    in {
      overrideChangesDrv = drv [on custom] != drv [on];
      defaultStable = drv [on] == drv [on];
    };
    expected = {
      overrideChangesDrv = true;
      defaultStable = true;
    };
  };

  # The statusline prints directory/worktree/PR strings through `printf %b`
  # into a terminal, so each must pass through sanitize_display first.
  testClaudeManagedSettingsStatuslineSanitizesUntrustedFields = {
    expr = let
      src = builtins.readFile ../modules/nixos/claude-managed-settings/statusline-command.sh;
      sanitized = f: lib.hasInfix ("${f}=$(sanitize_display \"" + "$" + f + "\")") src;
    in
      builtins.all sanitized ["model" "effort" "wt_name" "pr_number" "pr_url" "pr_state"]
      && lib.hasInfix "base=$(sanitize_display \"$(basename" src;
    expected = true;
  };
}
