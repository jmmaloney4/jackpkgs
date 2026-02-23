# lib/opencode.nix — lib.opencode helpers
#
# Exposed on the jackpkgs flake as lib.opencode.mkConfig.
#
# mkConfig :: pkgs -> config -> path
#   Generates an opencode.json Nix store path from an option-attrset that
#   mirrors the perSystem jackpkgs.opencode module options:
#
#   {
#     mcp.time.enable = true;
#     mcp.time.timezone = "America/Chicago";
#     mcp.serena.enable = true;
#     mcp.serena.context = "claude-code";
#     mcp.serena.extraPackages = [];
#     mcp.github.enable = true;
#     mcp.github.remote = true;
#     mcp.github.tokenEnvVar = "GITHUB_TOKEN";
#     mcp.context7.enable = true;
#     mcp.context7.apiKeyEnvVar = "CONTEXT7_API_KEY";
#     mcp.jujutsu.enable = true;
#     mcp.claudeContext.enable = true;
#     mcp.extra = {};
#     settings = {};
#   }
#
# All keys are optional; absent keys default to disabled/empty.
# Useful for Home Manager modules or any context outside a flake-parts perSystem.

{ lib, mcpNixFlake }:

let
  # Fill in defaults for any unset options so buildOpencodeConfig can be
  # called with a partial attrset from HM module or arbitrary callers.
  withDefaults = cfg:
    let
      d = def: val: if val == null then def else val;
      b = val: if val == null then false else val;
    in
    {
      mcp = {
        time = {
          enable = b (cfg.mcp.time.enable or null);
          timezone = d "America/Chicago" (cfg.mcp.time.timezone or null);
        };
        serena = {
          enable = b (cfg.mcp.serena.enable or null);
          context = cfg.mcp.serena.context or null;
          extraPackages = cfg.mcp.serena.extraPackages or [ ];
        };
        github = {
          enable = b (cfg.mcp.github.enable or null);
          remote = d true (cfg.mcp.github.remote or null);
          tokenEnvVar = d "GITHUB_TOKEN" (cfg.mcp.github.tokenEnvVar or null);
        };
        context7 = {
          enable = b (cfg.mcp.context7.enable or null);
          apiKeyEnvVar = d "CONTEXT7_API_KEY" (cfg.mcp.context7.apiKeyEnvVar or null);
        };
        jujutsu = {
          enable = b (cfg.mcp.jujutsu.enable or null);
        };
        claudeContext = {
          enable = b (cfg.mcp.claudeContext.enable or null);
        };
        extra = cfg.mcp.extra or { };
      };
      settings = cfg.settings or { };
    };

  buildOpencodeConfig = pkgs: ocCfg:
    let
      mcpNix = mcpNixFlake;

      nixPackagedPrograms =
        lib.optionalAttrs ocCfg.mcp.time.enable {
          time = {
            enable = true;
            env.LOCAL_TIMEZONE = ocCfg.mcp.time.timezone;
          };
        }
        // lib.optionalAttrs ocCfg.mcp.serena.enable {
          serena =
            { enable = true; }
            // lib.optionalAttrs (ocCfg.mcp.serena.context != null) {
              context = ocCfg.mcp.serena.context;
            }
            // lib.optionalAttrs (ocCfg.mcp.serena.extraPackages != [ ]) {
              extraPackages = ocCfg.mcp.serena.extraPackages;
            };
        }
        // lib.optionalAttrs (ocCfg.mcp.github.enable && !ocCfg.mcp.github.remote) {
          github = { enable = true; };
        };

      nixMcpServers =
        if nixPackagedPrograms != { }
        then
          let
            configFile = mcpNix.lib.mkConfig pkgs {
              flavor = "opencode";
              fileName = "opencode.json";
              programs = nixPackagedPrograms;
            };
            parsed = builtins.fromJSON (builtins.readFile configFile);
          in
            parsed.mcp or { }
        else { };

      remoteMcpServers =
        lib.optionalAttrs (ocCfg.mcp.github.enable && ocCfg.mcp.github.remote) {
          github = {
            type = "remote";
            url = "https://api.githubcopilot.com/mcp";
            headers = {
              Authorization = "{env:${ocCfg.mcp.github.tokenEnvVar}}";
              X-MCP-Toolsets = "all";
            };
            enabled = true;
          };
        }
        // lib.optionalAttrs ocCfg.mcp.context7.enable (
          {
            context7 = {
              type = "remote";
              url = "https://mcp.context7.com/mcp";
              enabled = true;
            } // lib.optionalAttrs (ocCfg.mcp.context7.apiKeyEnvVar != null) {
              headers = {
                CONTEXT7_API_KEY = "{env:${ocCfg.mcp.context7.apiKeyEnvVar}}";
              };
            };
          }
        );

      npxMcpServers =
        lib.optionalAttrs ocCfg.mcp.jujutsu.enable {
          jujutsu = {
            type = "local";
            command = [ "${pkgs.nodejs}/bin/npx" "jj-mcp-server" ];
            enabled = true;
          };
        }
        // lib.optionalAttrs ocCfg.mcp.claudeContext.enable {
          "claude-context" = {
            type = "local";
            command = [ "${pkgs.nodejs}/bin/npx" "@zilliz/claude-context-mcp@latest" ];
            enabled = true;
          };
        };

      allMcp =
        nixMcpServers
        // remoteMcpServers
        // npxMcpServers
        // ocCfg.mcp.extra;
    in
      lib.recursiveUpdate { mcp = allMcp; } ocCfg.settings;

in
{
  /**
  Generate an opencode.json file in the Nix store from a config attrset.

  Accepts the same shape as the perSystem `jackpkgs.opencode` module options.
  All keys are optional.

  Example:

  ```nix
  jackpkgs.lib.opencode.mkConfig pkgs {
    mcp.time.enable = true;
    mcp.github = { enable = true; tokenEnvVar = "GITHUB_TOKEN"; };
    mcp.context7.enable = true;
    settings.model = "anthropic/claude-sonnet-4-5";
  }
  ```

  Returns a path to the generated `opencode.json` in the Nix store.
  */
  mkConfig = pkgs: cfg:
    let
      ocCfg = withDefaults cfg;
      fullConfig = buildOpencodeConfig pkgs ocCfg;
    in
      pkgs.writeText "opencode.json" (builtins.toJSON fullConfig);
}
