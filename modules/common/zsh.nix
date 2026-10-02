# jackpkgs.zsh — system zsh, plus exporting env vars from secret files at
# shell init (ADR-050 fleet glue).
#
# Promoted from garden `nixfiles/modules/common/zsh.nix` (garden#2074 Part B
# PR 2). Garden's copy exported one named agenix secret
# (`age.secrets.hermes-op-token`) fleet-wide; per ADR-050's PR 2 plan and
# garden#2074 decision 5 that binding is gone. `secretEnv` is the general
# form — the consumer names the variable and the file, and scopes it to the
# hosts that need it.
{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) attrNames concatStrings escapeShellArg filter mapAttrsToList mkEnableOption mkIf mkMerge mkOption types;
  cfg = config.jackpkgs.zsh;

  # POSIX env var names: the key is interpolated into shell unquoted, so it
  # is refused at a single chokepoint (the assertion below) rather than
  # escaped.
  isEnvName = name: builtins.match "[A-Za-z_][A-Za-z0-9_]*" name != null;
  badNames = filter (n: !isEnvName n) (attrNames cfg.secretEnv);
in {
  options.jackpkgs.zsh = {
    enable = mkEnableOption "system zsh as the default shell environment (completion, SHELL, LANG)";

    secretEnv = mkOption {
      # An absolute-path *string*, not `types.path`: a literal `./token` under
      # `types.path` would be copied into the world-readable store at eval
      # time, defeating the point of holding the secret elsewhere.
      type = types.attrsOf (types.strMatching "^/.*");
      default = {};
      example = lib.literalExpression ''
        {
          MY_SERVICE_TOKEN = config.age.secrets.my-service-token.path;
        }
      '';
      description = ''
        Environment variables exported in every login/interactive shell from
        the contents of a secret file, read at shell start (never copied into
        the Nix store). Keys are variable names; values are absolute paths. A
        file the shell user cannot read is skipped silently, so the secret's
        own permissions decide who gets the variable.

        No secret is bound by default — wire only the hosts that need it.
        Requires `jackpkgs.zsh.enable`.
      '';
    };
  };

  config = mkMerge [
    {
      assertions = [
        {
          assertion = badNames == [];
          message = "jackpkgs.zsh.secretEnv: not valid environment variable names: ${toString badNames}";
        }
        {
          # Refuse rather than silently export nothing.
          assertion = cfg.secretEnv == {} || cfg.enable;
          message = "jackpkgs.zsh.secretEnv is set but jackpkgs.zsh.enable is not; the variables would never be exported.";
        }
      ];
    }
    (mkIf cfg.enable {
      programs.zsh.enable = true;
      programs.zsh.enableBashCompletion = true;

      # Darwin only: let home-manager own the compinit call. /etc/zshrc runs
      # before ~/.zshrc, so its compinit is the first to reach Homebrew's
      # completion directory and trip compaudit's "insecure directories" prompt
      # for every user who does not own /opt/homebrew. home-manager's
      # completionInit re-runs compinit moments later anyway, so this call is
      # redundant *and* the one that nags. enableCompletion stays true (it still
      # pulls in nix-zsh-completions) and `bashcompinit` loads fine without it.
      programs.zsh.enableGlobalCompInit = mkIf pkgs.stdenv.hostPlatform.isDarwin false;

      environment.variables.SHELL = "${pkgs.zsh}/bin/zsh";
      environment.variables.LANG = "en_US.UTF-8";

      # see: https://nix-community.github.io/home-manager/options.html#opt-programs.zsh.enableCompletion
      environment.pathsToLink = ["/share/zsh"];

      environment.shellInit = concatStrings (mapAttrsToList (name: path: ''
          if [ -r ${escapeShellArg path} ]; then
            export ${name}="$(<${escapeShellArg path})"
          fi
        '')
        cfg.secretEnv);
    })
  ];
}
