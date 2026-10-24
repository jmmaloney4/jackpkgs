# Git-aware author/committer gate for Cursor cloud agents.
#
# Why this is an app + hook, not a pure `checks.*` derivation: Nix copies a
# flake to the store without `.git`, so a sandboxed check cannot read
# `git log`. Fleet merge is `nix flake check -L` in a worktree — that still
# builds those git-less copies. The gate that actually sees history is this
# CLI, invoked from the worktree (`nix run`, `just author-gate`, pre-push).
{jackpkgsInputs}: {
  config,
  lib,
  ...
}: let
  inherit (lib) mkIf mkEnableOption mkOption types;
  inherit (jackpkgsInputs.flake-parts.lib) mkDeferredModuleOption;
  cfg = config.jackpkgs.author-gate;
in {
  imports = [./just-features.nix];

  options.jackpkgs.author-gate = {
    enable =
      mkEnableOption "author-gate app, just recipe, and rewrite-hint defaults"
      // {
        default = true;
        description = ''
          Export `apps.author-gate` / `apps.git-bot-identity` and a
          `just author-gate` recipe. Does **not** add a pure flake check of
          the consumer repo's history (the store copy has no `.git`).
          Default on; safe because it only adds an app and a just recipe.
        '';
      };
  };

  options.perSystem = mkDeferredModuleOption ({
    config,
    lib,
    pkgs,
    system,
    ...
  }: {
    options.jackpkgs.author-gate = {
      package = mkOption {
        type = types.package;
        default = jackpkgsInputs.self.packages.${system}.author-gate;
        defaultText = "jackpkgsInputs.self.packages.\${system}.author-gate";
        description = ''
          The author-gate CLI. Fails when any commit in
          `merge-base(origin/<default>, HEAD)..HEAD` has author or
          committer email `cursoragent@cursor.com`.
        '';
      };

      identityPackage = mkOption {
        type = types.package;
        default = jackpkgsInputs.self.packages.${system}.git-bot-identity;
        defaultText = "jackpkgsInputs.self.packages.\${system}.git-bot-identity";
        description = "CLI that sets repo-local git user.name/email from GROKBOT_GIT_* or a Bot: trailer.";
      };

      botEmailDomain = mkOption {
        type = types.str;
        default = "bots.roomofrequirement.xyz";
        description = ''
          Domain used in the rewrite hint: `<name>@<domain>` parsed from
          `Bot: <name> (<Title>)`. Cavins bots should set
          `bots.cavinsresearch.io`.
        '';
      };

      blockedEmails = mkOption {
        type = types.listOf types.str;
        default = ["cursoragent@cursor.com"];
        description = "Author or committer emails that fail the gate. Other authors are not flagged.";
      };
    };
  });

  config = mkIf cfg.enable {
    perSystem = {
      config,
      lib,
      ...
    }: let
      sysCfg = config.jackpkgs.author-gate;
      justfileHelpers = import ../../lib/justfile-helpers.nix {inherit lib;};
      inherit (justfileHelpers) mkRecipe;
      blockedFlags = lib.concatMapStringsSep " " (e: "--blocked-email ${lib.escapeShellArg e}") sysCfg.blockedEmails;
    in {
      apps.author-gate = {
        type = "app";
        program = lib.getExe sysCfg.package;
      };
      apps.git-bot-identity = {
        type = "app";
        program = lib.getExe sysCfg.identityPackage;
      };
      jackpkgs.justFeatures.author-gate = {
        enable = true;
        justfile =
          mkRecipe "author-gate" "Fail if commits since origin/<default> are cursoragent@cursor.com" [
            "${lib.getExe sysCfg.package} --bot-email-domain ${lib.escapeShellArg sysCfg.botEmailDomain} ${blockedFlags}"
          ]
          false;
      };
    };
  };
}
