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

          Note: the deps FOD installs with --frozen-lockfile (see `pnpmDeps`
          below). pnpm 11.4.0+ fails closed with ERR_PNPM_MISSING_TARBALL_INTEGRITY
          on `https://….tgz` (GitHub-release) dependencies whose pnpm-lock.yaml
          `resolution: {tarball: …}` entry has no `integrity` field — pnpm does not
          write one for URL tarballs. Hand-add `integrity: sha512-…` to each such
          resolution block before refreshing this hash. This recurs on every
          tarball-dep version bump.
        '';
      };

      projectRoot = mkOption {
        type = types.path;
        default = config.jackpkgs.projectRoot or inputs.self.outPath;
        defaultText = "config.jackpkgs.projectRoot or inputs.self.outPath";
        description = "Root of the Node.js project (containing pnpm-lock.yaml and pnpm-workspace.yaml).";
      };

      prePnpmInstall = mkOption {
        type = types.lines;
        default = "";
        example = "export pnpm_config_network_concurrency=4";
        description = ''
          Extra shell commands run inside the pnpm deps FOD right before
          `pnpm install`. Tweaking fetch behavior here cannot invalidate
          `pnpmDepsHash` as long as the fetched content is unchanged (FODs
          are verified by output hash only).
        '';
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
          default = config.jackpkgs.pkgs.nodejs_24;
          defaultText = "config.jackpkgs.pkgs.nodejs_24";
          description = "Node.js package to use.";
        };

        pnpmPackage = mkOption {
          type = types.package;
          # Run pnpm on nodejs-slim_latest instead of its default node runtime:
          # the nixpkgs build of nodejs_24 24.15.0 has broken worker_threads fd
          # tracking on aarch64-darwin — pnpm's install workers spam "File
          # descriptor N opened in unmanaged mode twice" and the process is
          # SIGKILLed (EXC_GUARD) at worker exit, which kills the deps FOD
          # right after `pnpm install` completes. nodejs 26 is unaffected.
          # Revisit once nixpkgs ships nodejs_24 >= 24.16.0.
          # https://github.com/NixOS/nixpkgs/issues/525627
          default = config.jackpkgs.pkgs.pnpm_11.override {
            nodejs-slim = config.jackpkgs.pkgs.nodejs-slim_latest;
          };
          defaultText = "config.jackpkgs.pkgs.pnpm_11.override { nodejs-slim = config.jackpkgs.pkgs.nodejs-slim_latest; }";
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
      sysCfg = config.jackpkgs.nodejs;

      # Installs with --frozen-lockfile. pnpm 11.4.0+ (pnpmPackage defaults to
      # pkgs.pnpm_11) fails closed on GitHub-release `.tgz` deps whose lockfile
      # resolution has no `integrity` field (ERR_PNPM_MISSING_TARBALL_INTEGRITY);
      # such entries need a hand-added `integrity:` line. See pnpmDepsHash above.
      pnpmDeps = pkgs.fetchPnpmDeps {
        pname = "pnpm";
        src = cfg.projectRoot;
        fetcherVersion = 3;
        pnpm = sysCfg.pnpmPackage;
        hash = cfg.pnpmDepsHash;
        prePnpmInstall = cfg.prePnpmInstall;
      };

      nodeModules = pkgs.stdenv.mkDerivation {
        name = "node_modules";
        src = cfg.projectRoot;

        nativeBuildInputs = [
          sysCfg.package
          sysCfg.pnpmPackage
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

      # Buildable directly so `just update-pnpm-hash` can provoke the FOD hash
      # mismatch without building the entire devshell closure alongside it.
      packages.pnpm-deps = pnpmDeps;

      jackpkgs.outputs.nodejsDevShell = pkgs.mkShell {
        packages = [
          sysCfg.package
          sysCfg.pnpmPackage
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

      # Minimal CI devshell for pnpm operations (install, build, pack).
      # Follows ADR-013 CI devshell conventions: no inputsFrom, no dev tools,
      # no interactive shell enhancements. Uses mkShellNoCC to avoid pulling
      # in the full C toolchain (gcc, binutils) — node + pnpm don't need it.
      devShells.ci-pnpm = pkgs.mkShellNoCC {
        name = "ci-pnpm";
        packages = [
          sysCfg.package
          sysCfg.pnpmPackage
          pkgs.gh
          pkgs.jq
        ];
        CI = true;
      };

      jackpkgs.shell.inputsFrom =
        lib.optional (config.jackpkgs.outputs.nodejsDevShell != null)
        config.jackpkgs.outputs.nodejsDevShell;
    };
  };
}
