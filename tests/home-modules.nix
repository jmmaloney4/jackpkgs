# nix-unit tests for the shared Home Manager module set (modules/home-manager;
# ADR-051, garden#2074 Part B PR 3).
#
# What these pin, beyond "it evaluates":
#
#   * The ADR-051 Decision 4 contract: identity options have no default, so
#     enabling a module without wiring them FAILS at eval -- and importing the
#     module without enabling it does not.
#   * Signing is opt-in by a spelled `null`, not by a missing option.
#   * `jackpkgs.jujutsu` takes its identity from `jackpkgs.git`, not its own.
#
# Full instantiation is the separate `home-modules-instantiate` check.
{
  inputs,
  lib,
}: let
  common = import ./home-modules-common.nix {inherit inputs lib;};
  inherit (common) eval identity named;

  cfgOf = modules: (eval modules).config;
in {
  testDefaultImportIsInert = {
    expr = let
      c = cfgOf [];
    in {
      git = c.programs.git.enable;
      zsh = c.programs.zsh.enable;
      jj = c.programs.jujutsu.enable;
      starship = c.programs.starship.enable;
    };
    expected = {
      git = false;
      zsh = false;
      jj = false;
      starship = false;
    };
  };

  # Every flake output is a standalone-importable module (no sibling imports
  # missing), and importing one alongside `default` does not double-declare.
  testNamedOutputsStandAlone = {
    expr = lib.all (
      n:
        (inputs.home-manager.lib.homeManagerConfiguration {
          inherit (common) pkgs;
          modules = [common.base named.${n}];
        }).config.home.username
        == "alice"
    ) (builtins.attrNames named);
    expected = true;
  };

  testNamedPlusDefaultDedups = {
    expr = (cfgOf [named.git named.jujutsu]).jackpkgs.git.enable;
    expected = false;
  };

  # ---------------------------------------------------------------------
  # jackpkgs.git
  # ---------------------------------------------------------------------

  testGitIdentity = {
    expr = let
      s = (cfgOf [{jackpkgs.git = {enable = true;} // identity;}]).programs.git.settings;
    in {
      inherit (s.user) name email;
      pullRebase = s.pull.rebase;
    };
    expected = {
      name = "Alice Example";
      email = "alice@example.com";
      pullRebase = true;
    };
  };

  testGitNameRequired = {
    expr =
      (cfgOf [
        {
          jackpkgs.git = {
            enable = true;
            userEmail = "alice@example.com";
          };
        }
      ]).programs.git.settings.user.name;
    expectedError.type = "ThrownError";
    expectedError.msg = "jackpkgs\\.git\\.userName";
  };

  testGitEmailRequired = {
    expr =
      (cfgOf [
        {
          jackpkgs.git = {
            enable = true;
            userName = "Alice Example";
          };
        }
      ]).programs.git.settings.user.email;
    expectedError.type = "ThrownError";
    expectedError.msg = "jackpkgs\\.git\\.userEmail";
  };

  testGitNoSigningByDefault = {
    expr = let
      c = cfgOf [{jackpkgs.git = {enable = true;} // identity;}];
    in {
      signByDefault = c.programs.git.signing.signByDefault or null;
      gpgFormat = (c.programs.git.settings.gpg or {}) ? format;
      allowedSigners = c.home.file ? ".allowed_signers";
    };
    expected = {
      signByDefault = null;
      gpgFormat = false;
      allowedSigners = false;
    };
  };

  testGitSigning = {
    expr = let
      c = cfgOf [
        {
          jackpkgs.git =
            {
              enable = true;
              signing = {
                key = "ssh-ed25519 AAAA alice";
                program = "/usr/bin/signer";
              };
            }
            // identity;
        }
      ];
    in {
      sign = c.programs.git.signing.signByDefault;
      format = c.programs.git.settings.gpg.format;
      program = c.programs.git.settings.gpg.ssh.program;
      signers = c.home.file.".allowed_signers".text;
    };
    expected = {
      sign = true;
      format = "ssh";
      program = "/usr/bin/signer";
      signers = "alice@example.com ssh-ed25519 AAAA alice\n";
    };
  };

  testGitSigningProgramOverridableWithoutMkForce = {
    expr =
      (cfgOf [
        {
          jackpkgs.git =
            {
              enable = true;
              signing = {
                key = "ssh-ed25519 AAAA alice";
                program = "/usr/bin/signer";
              };
            }
            // identity;
          programs.git.settings.gpg.ssh.program = "/usr/bin/other";
        }
      ]).programs.git.settings.gpg.ssh.program;
    expected = "/usr/bin/other";
  };

  # ---------------------------------------------------------------------
  # jackpkgs.jujutsu
  # ---------------------------------------------------------------------

  testJujutsuTakesIdentityFromGit = {
    expr = let
      s =
        (cfgOf [
          {
            jackpkgs.git = {enable = true;} // identity;
            jackpkgs.jujutsu.enable = true;
          }
        ]).programs.jujutsu.settings;
    in {
      inherit (s.user) name email;
      signing = s ? signing;
    };
    expected = {
      name = "Alice Example";
      email = "alice@example.com";
      signing = false;
    };
  };

  testJujutsuIdentityRequired = {
    expr = (cfgOf [{jackpkgs.jujutsu.enable = true;}]).programs.jujutsu.settings.user.name;
    expectedError.type = "ThrownError";
    expectedError.msg = "jackpkgs\\.git\\.user(Name|Email)";
  };

  testJujutsuSigningKeyFromGit = {
    expr =
      (cfgOf [
        {
          jackpkgs.git =
            {
              enable = true;
              signing.key = "ssh-ed25519 AAAA alice";
            }
            // identity;
          jackpkgs.jujutsu.enable = true;
        }
      ]).programs.jujutsu.settings.signing.key;
    expected = "ssh-ed25519 AAAA alice";
  };

  # ---------------------------------------------------------------------
  # jackpkgs.shell
  # ---------------------------------------------------------------------

  testShellEnablesPrograms = {
    expr = let
      c = cfgOf [{jackpkgs.shell.enable = true;}];
    in {
      zsh = c.programs.zsh.enable;
      starship = c.programs.starship.enable;
      zellij = c.programs.zellij.enable;
      direnv = c.programs.direnv.nix-direnv.enable;
      ssh = c.programs.ssh.enable;
      forwardAgent = c.programs.ssh.settings."*".data.ForwardAgent;
    };
    expected = {
      zsh = true;
      starship = true;
      zellij = true;
      direnv = true;
      ssh = true;
      forwardAgent = true;
    };
  };

  testShellStateVersionIsTheConsumers = {
    expr = (cfgOf [{jackpkgs.shell.enable = true;}]).home.stateVersion;
    expected = "26.05"; # from `base`, not overridden by the module
  };

  testShellNoLocalAgentByDefault = {
    expr = let
      c = cfgOf [{jackpkgs.shell.enable = true;}];
      init = c.programs.zsh.initContent;
    in {
      match = lib.hasInfix "IdentityAgent" (c.programs.ssh.extraConfig or "");
      forwarded = lib.hasInfix "ssh_auth_sock" init;
      local = lib.hasInfix "-S \"$HOME/" init;
    };
    expected = {
      match = false;
      forwarded = true;
      local = false;
    };
  };

  testShellLocalAgentSocket = {
    expr = let
      c = cfgOf [
        {
          jackpkgs.shell = {
            enable = true;
            localSshAgentSocket = ".1password/agent.sock";
          };
        }
      ];
    in {
      ssh = lib.hasInfix "IdentityAgent \"~/.1password/agent.sock\"" c.programs.ssh.extraConfig;
      zsh = lib.hasInfix "export SSH_AUTH_SOCK=\"$HOME/.1password/agent.sock\"" c.programs.zsh.initContent;
    };
    expected = {
      ssh = true;
      zsh = true;
    };
  };

  # The socket path is interpolated into zsh and ssh_config; a quote or a
  # leading "/" would produce broken config, so the type refuses them.
  testShellLocalAgentSocketRefusesAbsolute = {
    expr =
      (cfgOf [
        {
          jackpkgs.shell = {
            enable = true;
            localSshAgentSocket = "/abs/agent.sock";
          };
        }
      ]).programs.ssh.extraConfig;
    expectedError.type = "ThrownError";
    expectedError.msg = "localSshAgentSocket";
  };

  testShellLocalAgentSocketRefusesQuote = {
    expr =
      (cfgOf [
        {
          jackpkgs.shell = {
            enable = true;
            localSshAgentSocket = "a\"b";
          };
        }
      ]).programs.ssh.extraConfig;
    expectedError.type = "ThrownError";
    expectedError.msg = "localSshAgentSocket";
  };

  testShellLocalAgentSocketAllowsSpaces = {
    expr =
      (cfgOf [
        {
          jackpkgs.shell = {
            enable = true;
            localSshAgentSocket = "Library/Group Containers/x/agent.sock";
          };
        }
      ]).programs.ssh.extraConfig
      != "";
    expected = true;
  };

  # ---------------------------------------------------------------------
  # jackpkgs.cargo / jackpkgs.build-user
  # ---------------------------------------------------------------------

  testCargoBuildJobs = {
    expr =
      (cfgOf [
        {
          jackpkgs.cargo = {
            enable = true;
            buildJobs = 4;
          };
        }
      ]).home.sessionVariables.CARGO_BUILD_JOBS;
    expected = "4";
  };

  testCargoNullJobsSetsNothing = {
    expr = (cfgOf [{jackpkgs.cargo.enable = true;}]).home.sessionVariables ? CARGO_BUILD_JOBS;
    expected = false;
  };

  testBuildUserProfile = {
    expr = let
      c = cfgOf [{jackpkgs.build-user.enable = true;}];
    in {
      email = c.programs.git.settings.user.email;
      bash = c.programs.bash.enable;
      home = c.home.homeDirectory;
    };
    expected = {
      email = "build@localhost";
      bash = true;
      home = "/home/alice";
    };
  };
}
