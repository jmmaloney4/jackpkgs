# jackpkgs.git — git, gh and difftastic for Home Manager (ADR-051).
# Promoted from garden `nixfiles/home/programs/git.nix` (`jmmaloney4.git`).
#
# Identity is the point of the parameterization (ADR-051 Decision 4): the
# committer name/email and the signing key were hardcoded in garden and are
# required options here, with no default. Aliases, ignores, rebase-on-pull and
# the other taste settings stay baked.
{
  config,
  lib,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkMerge mkOption types;
  cfg = config.jackpkgs.git;
  signing = cfg.signing.key != null;
in {
  options.jackpkgs.git = {
    enable = mkEnableOption "git, gh and difftastic with jackpkgs' aliases and defaults";

    userName = mkOption {
      type = types.str;
      example = "Alice Example";
      description = ''
        Committer name. Required when `jackpkgs.git.enable` is set: there is
        deliberately no default, since a name is identity (ADR-051 Decision 4).
      '';
    };

    userEmail = mkOption {
      type = types.str;
      example = "alice@example.com";
      description = ''
        Committer email. Required when `jackpkgs.git.enable` is set: there is
        deliberately no default (ADR-051 Decision 4).
      '';
    };

    signing = {
      # nullOr + default null, not a required option: "this account does not
      # sign" is an intended state (a build box, a CI user), so it is spelled
      # rather than left to fail (ADR-051 Decision 3, optional capabilities).
      key = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "ssh-ed25519 AAAAC3Nza… alice@laptop";
        description = ''
          SSH public key used to sign commits. `null` (the default) configures
          no signing at all. When set, git signs with the SSH format, and
          `~/.allowed_signers` is written so `git log --show-signature` can
          verify commits made by `userEmail`.
        '';
      };

      signByDefault = mkOption {
        type = types.bool;
        default = true;
        description = "Sign every commit and tag. Only meaningful when `signing.key` is set.";
      };

      program = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "/Applications/1Password.app/Contents/MacOS/op-ssh-sign";
        description = ''
          Program git runs to produce SSH signatures (`gpg.ssh.program`).
          `null` leaves git's default (`ssh-keygen`, which signs through
          whatever agent holds `signing.key`). Only meaningful when
          `signing.key` is set.
        '';
      };
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      programs.gh.enable = true;
      programs.gh.settings.git_protocol = "ssh";

      programs.difftastic = {
        enable = true;
        git.enable = true;
      };

      programs.git = {
        enable = true;
        lfs.enable = true;

        settings = {
          user = {
            name = cfg.userName;
            email = cfg.userEmail;
          };

          alias = {
            a = "add -A";
            s = "status";
            f = "fetch";
            co = "checkout";
            cp = "cherry-pick";
            ff = "merge --ff-only";
            rb = "rebase";
            fff = "pull --ff-only";

            remotes = "remote -v show";
            branches = "branch -a -vv";
            dc = "diff --cached";

            j = "log --oneline --decorate --graph --all --abbrev-commit";
            l = "log --oneline --decorate --graph --all --abbrev-commit";
            lg = ''log --full-history --graph --color --pretty=format:"%C(yellow)%H%C(green)%d%C(reset)%n%x20%cd%n%x20%cn%C(blue)%x20(%ce)%x20%C(cyan)[gpg:%GK%x20%G?]%C(reset)%n%x20%s%n"'';
            graph = "lg --all";
            tree = "graph --oneline";
          };

          pull.rebase = true;
          branch.autoSetupRebase = "always";
          push.autoSetupRemote = true;
          merge.commit = false;
          core.editor = "vim";

          init.defaultBranch = "main";
        };

        ignores = [
          "*~"
          "**/.DS_Store"
          ".DocumentRevisions-V100"
          ".fseventsd"
          ".Spotlight-V100"
          ".TemporaryItems"
          ".Trashes"
          ".VolumeIcon.icns"
          ".com.apple.timemachine.donotpresent"
          "secring.*"
        ];
      };
    }

    (mkIf signing {
      programs.git.signing = {
        format = "ssh";
        inherit (cfg.signing) key signByDefault;
      };
      programs.git.settings = {
        gpg.format = "ssh";
        gpg.ssh.allowedSignersFile = "~/.allowed_signers";
      };
      home.file.".allowed_signers".text = ''
        ${cfg.userEmail} ${cfg.signing.key}
      '';
    })

    (mkIf (signing && cfg.signing.program != null) {
      # mkDefault: a consumer that needs a different program for one host can
      # still override it through programs.git.settings.
      programs.git.settings.gpg.ssh.program = lib.mkDefault cfg.signing.program;
    })
  ]);
}
