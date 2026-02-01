{jackpkgsInputs}: {
  inputs,
  config,
  lib,
  jackpkgsLib,
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
      enable = mkEnableOption "jackpkgs-nodejs (opinionated Node.js envs via buildNpmPackage)" // {default = false;};

      version = mkOption {
        type = types.enum [18 20 22];
        default = 22;
        description = "Node.js major version to use.";
      };

      projectRoot = mkOption {
        type = types.path;
        default = config.jackpkgs.projectRoot or inputs.self.outPath;
        defaultText = "config.jackpkgs.projectRoot or inputs.self.outPath";
        description = "Root of the Node.js project (containing package.json/package-lock.json).";
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
        description = "The node_modules derivation built by buildNpmPackage.";
      };

      options.jackpkgs.outputs.nodejsDevShell = mkOption {
        type = types.nullOr types.package;
        default = null;
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

      # Package npm-lockfile-fix for fixing workspace lockfiles
      # See ADR-022: npm v9+ workspace lockfiles omit resolved/integrity for nested deps
      npmLockfileFix = pkgs.python3Packages.buildPythonApplication {
        pname = "npm-lockfile-fix";
        version = "0.1.1";
        pyproject = true;

        src = pkgs.fetchFromGitHub {
          owner = "jeslie0";
          repo = "npm-lockfile-fix";
          rev = "v0.1.1";
          hash = "sha256-P93OowrVkkOfX5XKsRsg0c4dZLVn2ZOonJazPmHdD7g=";
        };

        build-system = [pkgs.python3Packages.setuptools];
        propagatedBuildInputs = [pkgs.python3Packages.requests];

        meta = {
          mainProgram = "npm-lockfile-fix";
          description = "Add missing integrity and resolved fields to npm workspace lockfiles";
          homepage = "https://github.com/jeslie0/npm-lockfile-fix";
          license = pkgs.lib.licenses.mit;
        };
      };

      # Build node_modules using buildNpmPackage
      nodeModules = pkgs.buildNpmPackage {
        pname = "node-modules";
        version = "1.0.0";
        src = cfg.projectRoot;
        nodejs = nodejsPackage;
        npmDeps = pkgs.importNpmLock {npmRoot = cfg.projectRoot;};
        npmConfigHook = pkgs.importNpmLock.npmConfigHook;
        installPhase = ''
          cp -R node_modules $out
        ''; # See ADR-020 Appendix A: Custom installPhase preserves flat <store>/node_modules/ structure for API stability
      };
    in {
      # Expose node_modules and npm-lockfile-fix for consumption by checks
      jackpkgs.outputs.nodeModules = nodeModules;
      jackpkgs.outputs.npmLockfileFix = npmLockfileFix;

      # Create devshell fragment
      jackpkgs.outputs.nodejsDevShell = pkgs.mkShell {
        packages = [
          nodejsPackage
          npmLockfileFix
        ];

        # NOTE: We check for .bin paths at runtime (shellHook execution time), not at
        # Nix evaluation time, because the derivation doesn't exist yet during eval.
        # builtins.pathExists would always return false for unbuilt store paths.
        shellHook = ''
          node_modules_bin=""
          ${lib.optionalString (nodeModules != null) ''
            # Use Nix-built binaries from the node_modules derivation (pure, preferred)
            # TODO: Remove dream2nix fallback paths after migration period (see ADR-020)
            ${jackpkgsLib.nodejs.findNodeModulesBin "node_modules_bin" nodeModules}
          ''}
          if [ -n "$node_modules_bin" ]; then
            export PATH="$node_modules_bin:$PATH"
          else
            # Fallback: Add local node_modules/.bin for impure builds (npm install)
            # This allows the devshell to work even without Nix-built node_modules
            export PATH="$PWD/node_modules/.bin:$PATH"
          fi
        '';
      };

      # Auto-configure main devshell
      jackpkgs.shell.inputsFrom =
        lib.optional (config.jackpkgs.outputs.nodejsDevShell != null)
        config.jackpkgs.outputs.nodejsDevShell;
    };
  };
}
