# ADR-032: opencode configuration flake-parts module
#
# Provides two consumption patterns:
#   1. perSystem module (project-level, "zeus" pattern): enables
#      packages.opencode-config and a shellHook that symlinks opencode.json
#      into $PRJ_ROOT on devShell entry.
#   2. lib.opencode.mkConfig pkgs config (user-level, "garden"/HM pattern):
#      returns a Nix store path to the generated opencode.json; exposed on
#      the jackpkgs flake as lib.opencode.mkConfig.
#
# MCP server packaging strategy:
#   - Nix-packaged (serena, time, github local): isolated derivations via
#     natsukium/mcp-servers-nix — no uvx/npx at runtime, no PYTHONPATH leakage.
#   - Remote (github default, context7): plain attrset with opencode's own
#     {env:VAR} substitution in headers — tokens never enter the Nix store.
#   - npx-based (jujutsu, claude-context): use ${pkgs.nodejs}/bin/npx so at
#     least a deterministic Nix-managed Node binary is used.

{ jackpkgsInputs }:
{ inputs, config, lib, ... }:

let
  inherit (lib) mkIf;
  inherit (jackpkgsInputs.flake-parts.lib) mkDeferredModuleOption;

  cfg = config.jackpkgs.opencode;

  # Delegate to lib/opencode.nix — single source of truth for config generation.
  opencodeLib = import ../../lib/opencode.nix {
    inherit lib;
    mcpNixFlake = jackpkgsInputs.mcp-servers-nix;
  };

in
{
  # ---------------------------------------------------------------------------
  # Top-level (non-perSystem) options
  # ---------------------------------------------------------------------------
  options = {
    jackpkgs.opencode = {
      enable = lib.mkEnableOption "jackpkgs opencode configuration module";
    };

    # Per-system options declared via mkDeferredModuleOption so they receive pkgs
    perSystem = mkDeferredModuleOption (
      { config, lib, pkgs, ... }:
      let
        inherit (lib) mkEnableOption mkOption literalExpression;
        inherit (lib.types) bool str nullOr listOf attrsOf anything enum package;
      in
      {
        options.jackpkgs.opencode = {

          # ----------------------------------------------------------------
          # MCP server options
          # ----------------------------------------------------------------
          mcp = {
            time = {
              enable = mkEnableOption "time MCP server (mcp-server-time, Nix-packaged)";
              timezone = mkOption {
                type = str;
                default = "America/Chicago";
                description = "Local timezone passed to mcp-server-time via LOCAL_TIMEZONE env var.";
                example = "Europe/Berlin";
              };
            };

            serena = {
              enable = mkEnableOption "serena MCP server (Nix-packaged via mcp-servers-nix)";
              context = mkOption {
                type = nullOr (enum [
                  "agent"
                  "chatgpt"
                  "claude-code"
                  "codex"
                  "desktop-app"
                  "ide-assistant"
                  "oaicompat-agent"
                ]);
                default = null;
                description = "Client context hint passed to serena as --context.";
                example = "claude-code";
              };
              extraPackages = mkOption {
                type = listOf package;
                default = [ ];
                description = "Extra packages prepended to PATH for serena (e.g. language servers, runtimes).";
                example = literalExpression "[ pkgs.python3 pkgs.rust-analyzer ]";
              };
            };

            github = {
              enable = mkEnableOption "GitHub MCP server";
              remote = mkOption {
                type = bool;
                default = true;
                description = ''
                  When true (default), configure the remote GitHub Copilot MCP
                  endpoint (https://api.githubcopilot.com/mcp). The token is
                  referenced via opencode's {env:tokenEnvVar} substitution so it
                  never enters the Nix store.

                  When false, use the locally-packaged github-mcp-server binary
                  (github.com/github/github-mcp-server) pointing at api.github.com.
                  Note: this is a functionally different server with different tool
                  capabilities.
                '';
              };
              tokenEnvVar = mkOption {
                type = str;
                default = "GITHUB_TOKEN";
                description = "Environment variable name holding the GitHub token.";
              };
            };

            context7 = {
              enable = mkEnableOption "context7 MCP server (remote, https://mcp.context7.com/mcp)";
              apiKeyEnvVar = mkOption {
                type = nullOr str;
                default = "CONTEXT7_API_KEY";
                description = ''
                  Environment variable name holding the Context7 API key.
                  Set to null to omit the Authorization header (anonymous access).
                '';
              };
            };

            jujutsu = {
              enable = mkEnableOption "jujutsu (jj) MCP server (npx jj-mcp-server)";
            };

            claudeContext = {
              enable = mkEnableOption "claude-context MCP server (npx @zilliz/claude-context-mcp)";
            };

            extra = mkOption {
              type = attrsOf anything;
              default = { };
              description = ''
                Freeform additional MCP server entries merged directly into the
                generated mcp section after all typed servers. Values must be valid
                opencode mcp server attrsets (type, command/url, enabled, etc.).
                Wins over typed server entries on key conflict.
              '';
              example = literalExpression ''
                {
                  my-custom-server = {
                    type = "local";
                    command = [ "/nix/store/.../bin/my-server" "--stdio" ];
                    enabled = true;
                  };
                }
              '';
            };
          };

          # ----------------------------------------------------------------
          # Freeform passthrough for the rest of opencode.json
          # ----------------------------------------------------------------
          settings = mkOption {
            type = attrsOf anything;
            default = { };
            description = ''
              Freeform opencode.json config merged after the generated mcp section.
              Wins over typed MCP options on key conflict.

              Use this for: provider, model, keybinds, plugin, lsp, agent,
              formatter, permission, $schema, theme, autoupdate, etc.

              Note: use the schema-correct "plugin" key (singular) for npm plugins,
              not "plugins" (plural) which is silently ignored by opencode.
            '';
            example = literalExpression ''
              {
                "''$schema" = "https://opencode.ai/config.json";
                plugin = [ "@tarquinen/opencode-dcp@latest" ];
                model = "anthropic/claude-sonnet-4-5";
                keybinds.app_exit = "ctrl+q";
                provider.anthropic.options.apiKey = "{env:ANTHROPIC_API_KEY}";
              }
            '';
          };

          # ----------------------------------------------------------------
          # Read-only output
          # ----------------------------------------------------------------
          configFile = mkOption {
            type = package;
            readOnly = true;
            description = ''
              The generated opencode.json as a Nix store path (pkgs.writeText).
              Also published as packages.opencode-config.
            '';
          };
        };
      }
    );
  };

  # ---------------------------------------------------------------------------
  # Config — wires the per-system options to outputs
  # ---------------------------------------------------------------------------
  config = mkIf cfg.enable {
    perSystem = { pkgs, lib, config, ... }:
      let
        ocCfg = config.jackpkgs.opencode;
        configFile = opencodeLib.mkConfig pkgs ocCfg;
      in
      {
        jackpkgs.opencode.configFile = configFile;

        packages.opencode-config = configFile;

        # Expose a devShell fragment that symlinks opencode.json into $PRJ_ROOT.
        # Consumers add this to jackpkgs.shell.inputsFrom or their own devShell.
        jackpkgs.shell.inputsFrom = [
          (pkgs.mkShell {
            shellHook = ''
              if [ -n "''${PRJ_ROOT:-}" ]; then
                ln -sf ${lib.escapeShellArg configFile} "$PRJ_ROOT/opencode.json"
              fi
            '';
          })
        ];
      };
  };
}
