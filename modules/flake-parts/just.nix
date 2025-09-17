{jackpkgsInputs}: {
  inputs,
  config,
  lib,
  ...
}: let
  inherit (lib) mkIf;
  cfg = config.jackpkgs.just;
in {
  imports = [
    jackpkgsInputs.just-flake.flakeModule
  ];

  options = let
    inherit (lib) types mkOption mkEnableOption;
    inherit (jackpkgsInputs.flake-parts.lib) mkDeferredModuleOption;
  in {
    jackpkgs.just = {
      enable = mkEnableOption "jackpkgs-just-flake" // {default = true;};
    };

    perSystem = mkDeferredModuleOption ({
      inputs',
      lib,
      pkgs,
      system,
      ...
    }: {
      options.jackpkgs.just = {
        direnvPackage = mkOption {
          type = types.package;
          default = pkgs.direnv;
          defaultText = "pkgs.direnv";
          description = "direnv package to use.";
        };
        fdPackage = mkOption {
          type = types.package;
          default = pkgs.fd;
          defaultText = "pkgs.fd";
          description = "fd package to use for finding files.";
        };
        flakeIterPackage = mkOption {
          type = types.package;
          default = jackpkgsInputs.flake-iter.packages.${system}.default;
          defaultText = "flake-iter.packages.default";
          description = "flake-iter package to use.";
        };
        googleCloudSdkPackage = mkOption {
          type = types.package;
          default = pkgs.google-cloud-sdk;
          defaultText = "pkgs.google-cloud-sdk";
          description = "google-cloud-sdk package to use.";
        };
        jqPackage = mkOption {
          type = types.package;
          default = pkgs.jq;
          defaultText = "pkgs.jq";
          description = "jq package to use.";
        };
        nbstripoutPackage = mkOption {
          type = types.package;
          default = pkgs.nbstripout;
          defaultText = "pkgs.nbstripout";
          description = "nbstripout package to use.";
        };
        preCommitPackage = mkOption {
          type = types.package;
          default = pkgs.pre-commit;
          defaultText = "pkgs.pre-commit";
          description = "pre-commit package to use.";
        };
        pulumiPackage = mkOption {
          type = types.package;
          default = pkgs.pulumi;
          defaultText = "pkgs.pulumi";
          description = "pulumi package to use.";
        };

        #
        pulumiBackendUrl = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Pulumi backend URL to use for authentication and stack operations. If not set, Pulumi login will be skipped.";
        };
      };
    });
  };

  config = mkIf cfg.enable {
    # Contribute per-system config as a function (this is the correct place for a function)
    perSystem = {
      pkgs,
      lib,
      config,
      ...
    }: let
      pcfg = config.jackpkgs.just; # per-system config scope
    in {
      just-flake = {
        features = {
          treefmt.enable = true;
          direnv = {
            enable = true;
            justfile = ''
              # Run direnv
              reload:
                  ${lib.getExe pcfg.direnvPackage} reload
              # alias for reload
              r:
                  @just reload
            '';
          };
          infra = {
            enable = true;
            justfile = ''
              # Authenticate with GCP and refresh ADC
              auth:
                  gcloud auth login --update-adc
                  gcloud auth application-default login

              # Create a new Pulumi stack (usage: just new-stack <project-path> <stack-name>)
              new-stack project_path stack_name:
                  ${lib.getExe pcfg.pulumiPackage} -C {{project_path}} login "$PULUMI_BACKEND_URL"
                  ${lib.getExe pcfg.pulumiPackage} -C {{project_path}} stack init {{stack_name}} --secrets-provider "$PULUMI_SECRETS_PROVIDER"
                  ${lib.getExe pcfg.pulumiPackage} -C {{project_path}} stack select {{stack_name}}
            '';
          };
          python = {
            enable = true;
            justfile = ''
              # Strip output from Jupyter notebooks
              nbstrip notebook="":
                  @if [ -z "{{notebook}}" ]; then \
                      ${lib.getExe pcfg.fdPackage} -e ipynb -x ${lib.getExe pcfg.nbstripoutPackage}; \
                  else \
                      ${lib.getExe pcfg.nbstripoutPackage} "{{notebook}}"; \
                  fi
            '';
          };
          git = {
            enable = true;
            justfile = ''
              # Run pre-commit hooks
              pre-commit:
                ${lib.getExe pcfg.preCommitPackage}
              # alias for pre-commit
              pre:
                @just pre-commit
              # Run pre-commit hooks on all files
              pre-all:
                ${lib.getExe pcfg.preCommitPackage} run --all-files
              
              # Release management
              release:
                #!/usr/bin/env bash
                set -euo pipefail
                
                echo "🏷️  Creating new semver minor release..." >&2
                
                # Always operate on origin/main, regardless of current checkout
                main_remote="origin"
                main_branch="main"
                
                echo "📥 Fetching latest from $main_remote..." >&2
                git fetch --tags --prune "$main_remote"
                git fetch "$main_remote" "$main_branch":"refs/remotes/$main_remote/$main_branch"
                
                if ! git rev-parse --verify --quiet "$main_remote/$main_branch" >/dev/null; then
                  echo "❌ Unable to find $main_remote/$main_branch. Ensure the remote and branch exist." >&2
                  exit 1
                fi
                
                # Note: We intentionally do not require a clean working directory or a checked-out branch.
                # The release tag is created against the remote tracking ref for main (origin/main).
                
                # Get the latest semver tag
                latest_tag=$(git tag --sort=-version:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
                
                if [ -z "$latest_tag" ]; then
                  echo "❌ No semver tags found. Please create an initial tag like v0.1.0 first." >&2
                  exit 1
                fi
                
                echo "📋 Latest tag: $latest_tag" >&2
                
                # Extract version numbers (remove 'v' prefix)
                version=${latest_tag#v}
                IFS='.' read -r major minor patch <<< "$version"
                
                # Increment minor version and reset patch to 0
                new_minor=$((minor + 1))
                new_version="$major.$new_minor.0"
                new_tag="v$new_version"
                
                echo "🆕 New tag: $new_tag" >&2
                
                # Create and push the tag (pointing at origin/main)
                target_commit=$(git rev-parse "$main_remote/$main_branch")
                echo "🏷️  Creating tag $new_tag at $main_remote/$main_branch ($target_commit)..." >&2
                git tag -a "$new_tag" -m "Release $new_tag" "$target_commit"
                
                echo "📤 Pushing tag to remote..." >&2
                git push origin "$new_tag"
                
                echo "✅ Successfully created and pushed release tag: $new_tag" >&2

              bump:
                #!/usr/bin/env bash
                set -euo pipefail
                
                echo "🏷️  Creating new semver patch release..." >&2
                
                # Always operate on origin/main, regardless of current checkout
                main_remote="origin"
                main_branch="main"
                
                echo "📥 Fetching latest from $main_remote..." >&2
                git fetch --tags --prune "$main_remote"
                git fetch "$main_remote" "$main_branch":"refs/remotes/$main_remote/$main_branch"
                
                if ! git rev-parse --verify --quiet "$main_remote/$main_branch" >/dev/null; then
                  echo "❌ Unable to find $main_remote/$main_branch. Ensure the remote and branch exist." >&2
                  exit 1
                fi
                
                # Note: We intentionally do not require a clean working directory or a checked-out branch.
                # The release tag is created against the remote tracking ref for main (origin/main).
                
                # Get the latest semver tag
                latest_tag=$(git tag --sort=-version:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
                
                if [ -z "$latest_tag" ]; then
                  echo "❌ No semver tags found. Please create an initial tag like v0.1.0 first." >&2
                  exit 1
                fi
                
                echo "📋 Latest tag: $latest_tag" >&2
                
                # Extract version numbers (remove 'v' prefix)
                version=${latest_tag#v}
                IFS='.' read -r major minor patch <<< "$version"
                
                # Increment patch version
                new_patch=$((patch + 1))
                new_version="$major.$minor.$new_patch"
                new_tag="v$new_version"
                
                echo "🆕 New tag: $new_tag" >&2
                
                # Create and push the tag (pointing at origin/main)
                target_commit=$(git rev-parse "$main_remote/$main_branch")
                echo "🏷️  Creating tag $new_tag at $main_remote/$main_branch ($target_commit)..." >&2
                git tag -a "$new_tag" -m "Release $new_tag" "$target_commit"
                
                echo "📤 Pushing tag to remote..." >&2
                git push origin "$new_tag"
                
                echo "✅ Successfully created and pushed release tag: $new_tag" >&2
            '';
          };
          nix = {
            enable = true;
            justfile = ''
              # Build all flake outputs using flake-iter
              build-all:
                ${lib.getExe pcfg.flakeIterPackage} build

              # Build all flake outputs with verbose output
              build-all-verbose:
                ${lib.getExe pcfg.flakeIterPackage} build --verbose
            '';
          };
        };
      };
    };
  };
}
