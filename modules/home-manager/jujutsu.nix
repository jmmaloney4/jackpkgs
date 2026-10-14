# jackpkgs.jujutsu — jj with git-friendly defaults (ADR-051).
# Promoted from garden `nixfiles/home/programs/jujutsu.nix`.
#
# Identity and the signing key are NOT options of this module: it reads them
# from `jackpkgs.git`, so a consumer states who they are once. Enabling this
# module without `jackpkgs.git.{userName,userEmail}` fails at eval ("option …
# used but not defined") -- by construction, not by assertion.
{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkMerge;
  cfg = config.jackpkgs.jujutsu;
  git = config.jackpkgs.git;
in {
  # jackpkgs.git is where the identity options live; import it so this module
  # stands alone as `homeModules.jujutsu`.
  imports = [./git.nix];

  options.jackpkgs.jujutsu.enable = mkEnableOption "jujutsu with git-familiar aliases and the identity from jackpkgs.git";

  config = mkIf cfg.enable (mkMerge [
    {
      programs.jujutsu = {
        enable = true;

        settings = {
          user = {
            name = git.userName;
            email = git.userEmail;
          };

          git = {
            # Allow fetching from Git repos
            abandon-unreachable-commits = false;
          };

          # Automatically track bookmarks from origin
          remotes.origin = {
            auto-track-bookmarks = "*";
          };

          fsmonitor.backend = "none";

          ui = {
            default-command = "log";
            color = "always";
            log-synthetic-elided-nodes = true;
            diff-editor = ":builtin";
            merge-editor = ":builtin";
            # A pager without shell-parsing issues.
            pager = "${lib.getExe pkgs.less} -FRX";
          };

          revset-aliases = {
            "HEAD" = "@";
            "main" = "main@origin";
            "master" = "master@origin";
            "unstaged" = "@";
            "all" = "::";
          };

          aliases = {
            "co" = ["checkout"];
            "br" = ["branch"];
            "ci" = ["commit"];

            "amend" = ["squash"];
            "fixup" = ["squash"];
            "unstage" = ["restore"];

            "lg" = ["log" "--template" "builtin_log_oneline"];
            "graph" = ["log" "--graph"];
            "oneline" = ["log" "--template" "builtin_log_oneline"];

            "push" = ["git" "push"];
            "pull" = ["git" "fetch"];
            "fetch" = ["git" "fetch"];

            "op-redo" = ["op" "redo"];
          };

          core.watchman = false;
        };
      };

      programs.zsh.shellAliases = mkIf config.programs.zsh.enable {
        "jgit" = "jj git";
        "jst" = "jj status";
        "jlog" = "jj log";
        "jshow" = "jj show";
        "jdiff" = "jj diff";
      };
    }

    (mkIf (git.signing.key != null) {
      programs.jujutsu.settings.signing = {
        # Carried over from garden unchanged: signing was dropped there to
        # work around 1Password SSH-agent failures. Nothing here turns it on;
        # a consumer wanting jj signatures sets
        # programs.jujutsu.settings.signing.behavior itself.
        behavior = "drop";
        backend = "ssh";
        inherit (git.signing) key;
      };
    })
  ]);
}
