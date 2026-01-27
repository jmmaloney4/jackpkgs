{jackpkgsInputs}: {
  inputs,
  config,
  lib,
  ...
}: let
  inherit (lib) mkIf;
  cfg = config.jackpkgs.nodejs;
in {
  imports = [
    jackpkgsInputs.flake-root.flakeModule
  ];

  options = let
    inherit (lib) types mkOption mkEnableOption;
    inherit (jackpkgsInputs.flake-parts.lib) mkDeferredModuleOption;
  in {
    jackpkgs.nodejs = {
      enable = mkEnableOption "jackpkgs-nodejs (opinionated Node.js envs via dream2nix)" // {default = false;};

      version = mkOption {
        type = types.enum [18 20 22];
        default = 22;
        description = "Node.js major version to use.";
      };

      projectRoot = mkOption {
        type = types.path;
        default = config.jackpkgs.projectRoot or inputs.self.outPath;
        defaultText = "config.jackpkgs.projectRoot or inputs.self.outPath";
        description = "Root of the Node.js project (containing package.json/pnpm-lock.yaml).";
      };

      packageManager = mkOption {
        type = types.enum ["pnpm"];
        default = "pnpm";
        description = "Package manager to use (currently only pnpm is supported).";
      };
    };

    perSystem = mkDeferredModuleOption ({
      config,
      lib,
      pkgs,
      system,
      ...
    }: {
      options.jackpkgs.outputs.nodeModules = mkOption {
        type = types.nullOr types.package;
        default = null;
        description = "The node_modules derivation built by dream2nix.";
      };

      options.jackpkgs.outputs.nodejsDevShell = mkOption {
        type = types.package;
        readOnly = true;
        description = "Node.js devShell fragment to include in `inputsFrom`.";
      };
    });
  };

  config = mkIf cfg.enable {
    perSystem = {
      pkgs,
      lib,
      config,
      system,
      ...
    }: let
      # Select Node.js package based on version option
      nodejsPackage =
        if cfg.version == 18
        then pkgs.nodejs_18
        else if cfg.version == 20
        then pkgs.nodejs_20
        else pkgs.nodejs_22; # Default to 22

      # Configure dream2nix to build the workspace
      dreamOutputs = jackpkgsInputs.dream2nix.lib.makeFlakeOutputs {
        systems = [system];
        config.projectRoot = cfg.projectRoot;
        source = cfg.projectRoot;
        projects = {
          default = {
            name = "default";
            relPath = "";
            subsystem = "nodejs";
            translator = "pnpm-lock";
            subsystemInfo = {
              nodejs = cfg.version;
            };
          };
        };
      };

      # Extract node_modules from dream2nix output
      # dream2nix structure: packages.${system}.default.lib.node_modules
      nodeModules = dreamOutputs.packages.${system}.default.lib.node_modules or null;
    in {
      # Expose node_modules for consumption by checks
      jackpkgs.outputs.nodeModules = nodeModules;

      # Create devshell fragment
      jackpkgs.outputs.nodejsDevShell = pkgs.mkShell {
        packages = [
          nodejsPackage
          pkgs.pnpm
        ];

        # NOTE: We check for .bin paths at runtime (shellHook execution time), not at
        # Nix evaluation time, because the derivation doesn't exist yet during eval.
        # builtins.pathExists would always return false for unbuilt store paths.
        shellHook = ''
          node_modules_bin=""
          ${lib.optionalString (nodeModules != null) ''
            # Use dream2nix-built binaries from Nix store (pure, preferred)
            # Check at runtime which structure dream2nix used
            if [ -d "${nodeModules}/lib/node_modules/.bin" ]; then
              node_modules_bin="${nodeModules}/lib/node_modules/.bin"
            elif [ -d "${nodeModules}/lib/node_modules/node_modules/.bin" ]; then
              node_modules_bin="${nodeModules}/lib/node_modules/node_modules/.bin"
            elif [ -d "${nodeModules}/node_modules/.bin" ]; then
              node_modules_bin="${nodeModules}/node_modules/.bin"
            fi
          ''}
          if [ -n "$node_modules_bin" ]; then
            export PATH="$node_modules_bin:$PATH"
          else
            # Fallback: Add local node_modules/.bin for impure builds (pnpm install)
            # This allows the devshell to work even without dream2nix-built node_modules
            export PATH="$PWD/node_modules/.bin:$PATH"
          fi
        '';
      };

      # Auto-configure main devshell
      jackpkgs.shell.inputsFrom = [
        config.jackpkgs.outputs.nodejsDevShell
      ];
    };
  };
}
