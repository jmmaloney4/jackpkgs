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
        description = "Root of Node.js project (containing package.json/package-lock.json). See Hermetic Constraints in README (ADR-022).";
      };

      importNpmLockOptions = mkOption {
        type = types.attrs;
        default = {};
        description = ''
          Additional options passed to pkgs.importNpmLock for configuring private registries or custom fetchers.

          This is a transparent pass-through to nixpkgs importNpmLock options.

          Example for private npm registry:
          {
            fetcherOpts = {
              "node_modules/@myorg" = {
                curlOptsList = [ "--header" "Authorization: Bearer ''${NPM_TOKEN}" ];
              };
            };
          }

          See nixpkgs importNpmLock documentation for full options.
        '';
        example = {
          fetcherOpts = {
            "node_modules/@myorg" = {
              curlOptsList = ["--header" "Authorization: Bearer token"];
            };
          };
        };
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

      # Build node_modules using buildNpmPackage
      nodeModules = pkgs.buildNpmPackage {
        pname = "node-modules";
        version = "1.0.0";
        src = cfg.projectRoot;
        nodejs = nodejsPackage;
        npmDeps = pkgs.importNpmLock ({npmRoot = cfg.projectRoot;} // cfg.importNpmLockOptions);
        npmConfigHook = pkgs.importNpmLock.npmConfigHook;

        # Preflight validation for hermetic builds (ADR-022)
        # Check package-lock.json for unsupported dependency forms before npm ci runs
        preBuild = ''
          if [ -f "package-lock.json" ]; then
            echo "Validating package-lock.json for hermetic Nix builds (ADR-022)..."
            ${pkgs.writeScript "validate-package-lock" ''
            #!${pkgs.runtimeShell}
            set -euo pipefail

            LOCKFILE="package-lock.json"

            if ! command -v jq >/dev/null 2>&1; then
              echo "Error: jq required for package-lock.json validation"
              echo "This is a build-time requirement for ADR-022 hermetic validation"
              exit 1
            fi

            echo "Parsing $LOCKFILE..."

            # Get all package entries (excluding workspace root which has no resolved)
            PACKAGES=$(jq -r '.packages | keys[] | select(. != "")' "$LOCKFILE" 2>/dev/null || true)

            ERRORS=0

            for pkg in $PACKAGES; do
              RESOLVED=$(jq -r ".packages[\"$pkg\"].resolved // \"\"" "$LOCKFILE" 2>/dev/null || echo "")
              INTEGRITY=$(jq -r ".packages[\"$pkg\"].integrity // \"\"" "$LOCKFILE" 2>/dev/null || echo "")

              # Skip workspace packages (they don't need resolved/integrity)
              if [ "$RESOLVED" = "" ] && [ "$INTEGRITY" = "" ]; then
                continue
              fi

              # Check for git dependencies
              if echo "$RESOLVED" | grep -qE '^(git\+https://|git\+ssh://|git://)'; then
                echo "ERROR: Git dependency detected: $pkg"
                echo "  Resolved: $RESOLVED"
                echo "  Git dependencies are not supported in hermetic Nix builds."
                echo "  Suggestion: Replace with npm registry version or publish to private registry."
                ERRORS=$((ERRORS + 1))
                continue
              fi

              # Check for file/link dependencies
              if echo "$RESOLVED" | grep -qE '^(file:|link:)'; then
                echo "ERROR: File or link dependency detected: $pkg"
                echo "  Resolved: $RESOLVED"
                echo "  File dependencies are not supported in hermetic Nix builds."
                echo "  Suggestion: Use npm workspaces or publish to registry."
                ERRORS=$((ERRORS + 1))
                continue
              fi

              # Check for missing integrity
              if [ -z "$INTEGRITY" ] && [ -n "$RESOLVED" ]; then
                echo "ERROR: Missing integrity field: $pkg"
                echo "  Suggestion: Regenerate lockfile with 'npm install'"
                ERRORS=$((ERRORS + 1))
                continue
              fi

              # Check for missing resolved
              if [ -z "$RESOLVED" ]; then
                echo "ERROR: Missing resolved field: $pkg"
                echo "  Suggestion: Regenerate lockfile with 'npm install'"
                ERRORS=$((ERRORS + 1))
                continue
              fi

              # Check for non-registry dependencies
              if ! echo "$RESOLVED" | grep -q "^https://registry.npmjs.org/" && \
                 echo "$RESOLVED" | grep -qE '^https?://'; then
                echo "WARNING: Non-registry dependency detected: $pkg"
                echo "  Resolved: $RESOLVED"
                echo "  This may require importNpmLockOptions.fetcherOpts configuration."
              fi
            done

            if [ "$ERRORS" -gt 0 ]; then
              echo ""
              echo "Hermetic npm dependency build validation failed (ADR-022)"
              echo ""
              echo "The following dependencies are incompatible with hermetic Nix builds:"
              echo ""
              echo "See ADR-022 and README (Hermetic Constraints section) for supported dependency forms."
              exit 1
            fi

            echo "Package-lock.json validation passed!"
          ''}

            ${pkgs.jq}/bin/jq --version || echo "jq not found"
            ${pkgs.jq}/bin/bash validate-package-lock
          else
            echo "Warning: package-lock.json not found, skipping validation"
          fi
        '';

        installPhase = ''
          cp -R node_modules $out
        ''; # See ADR-020 Appendix A: Custom installPhase preserves flat <store>/node_modules/ structure for API stability
      };
    in {
      # Expose node_modules for consumption by checks
      jackpkgs.outputs.nodeModules = nodeModules;

      # Create devshell fragment
      jackpkgs.outputs.nodejsDevShell = pkgs.mkShell {
        packages = [
          nodejsPackage
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
