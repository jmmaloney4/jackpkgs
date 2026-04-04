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
      enable = mkEnableOption "jackpkgs-nodejs (opinionated Node.js envs via pnpm)" // {default = false;};

      pnpmDepsHash = mkOption {
        type = types.str;
        default = "";
        example = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
        description = ''
          Hash for the pnpm deps FOD. Set to empty string initially,
          then run nix build to get the correct hash from the error message.
        '';
      };

      projectRoot = mkOption {
        type = types.path;
        default = config.jackpkgs.projectRoot or inputs.self.outPath;
        defaultText = "config.jackpkgs.projectRoot or inputs.self.outPath";
        description = "Root of the Node.js project (containing pnpm-lock.yaml and pnpm-workspace.yaml).";
      };
    };

    perSystem = mkDeferredModuleOption ({
      config,
      lib,
      pkgs,
      system,
      ...
    }: {
      options.jackpkgs.nodejs = {
        package = mkOption {
          type = types.package;
        default = pkgs.nodejs_24;
        defaultText = "pkgs.nodejs_24";
          description = "Node.js package to use.";
        };

        pnpmPackage = mkOption {
          type = types.package;
          default = pkgs.pnpm_10;
          defaultText = "pkgs.pnpm_10";
          description = "pnpm package to use.";
        };
      };

      options.jackpkgs.outputs.nodeModules = mkOption {
        type = types.nullOr types.package;
        default = null;
        description = "The node_modules derivation built via fetchPnpmDeps + pnpmConfigHook.";
      };

      options.jackpkgs.outputs.pnpmDeps = mkOption {
        type = types.nullOr types.package;
        default = null;
        description = "The pnpm deps FOD derivation (useful for debugging/caching).";
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
      pnpmDeps = pkgs.fetchPnpmDeps {
        pname = "pnpm";
        version = "1.0.0";
        src = cfg.projectRoot;
        fetcherVersion = 3;
        hash = cfg.pnpmDepsHash;
      };

      nodeModules = pkgs.stdenv.mkDerivation {
        pname = "node-modules";
        version = "1.0.0";
        src = cfg.projectRoot;

        nativeBuildInputs = [
          cfg.package
          cfg.pnpmPackage
          pkgs.pnpmConfigHook
        ];

        inherit pnpmDeps;

        CI = true;

        dontBuild = true;
        dontCheckForBrokenSymlinks = true;

        installPhase = ''
          mkdir -p "$out"
          cp -a node_modules "$out/"
          find . -mindepth 2 -name 'node_modules' -type d \
            -not -path './node_modules/*' | while read -r dir; do
            mkdir -p "$out/$(dirname "$dir")"
            cp -a "$dir" "$out/$dir"
          done
        '';
      };
    in {
      jackpkgs.outputs.nodeModules = nodeModules;
      jackpkgs.outputs.pnpmDeps = pnpmDeps;

      jackpkgs.outputs.nodejsDevShell = pkgs.mkShell {
        packages = [
          cfg.package
          cfg.pnpmPackage
        ];

        shellHook = ''
          node_modules_bin=""
          ${lib.optionalString (nodeModules != null) ''
            ${jackpkgsLib.nodejs.findNodeModulesBin "node_modules_bin" nodeModules}
          ''}
          if [ -n "$node_modules_bin" ]; then
            export PATH="$node_modules_bin:$PATH"
          else
            export PATH="$PWD/node_modules/.bin:$PATH"
          fi
        '';
      };

      jackpkgs.shell.inputsFrom =
        lib.optional (config.jackpkgs.outputs.nodejsDevShell != null)
        config.jackpkgs.outputs.nodejsDevShell;
    };
  };
}
