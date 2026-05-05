{jackpkgsInputs}: {
  inputs,
  config,
  lib,
  getSystem,
  ...
}: let
  inherit (lib) mkIf;
  cfg = config.jackpkgs.images;

  justfileHelpers = import ../../lib/justfile-helpers.nix {inherit lib;};
  inherit (justfileHelpers) mkRecipe mkRecipeWithParams;

  # Layer deduplication helper.
  # Builds new nix2container layers for each package, threading all previously-built
  # layers through so nix2container excludes store paths already present in earlier layers.
  # Uses prepend+reverse to maintain O(N) instead of O(N^2) with ++.
  foldImageLayers = nix2container: baseLayers: pkgList:
    let
      # acc holds layers in reverse order; we reverse at the end.
      # We reverse baseLayers so they also sit in the reversed accumulator.
      init = lib.reverseList baseLayers;
      fold = acc: drv:
        let
          layer = nix2container.buildLayer {
            copyToRoot = drv;
            # nix2container expects layers in forward (earliest-first) order,
            # so reverse back before passing.
            layers = lib.reverseList acc;
          };
        in
          [layer] ++ acc;
    in
      lib.reverseList (lib.foldl fold init pkgList);
in {
  options = let
    inherit (lib) types mkOption mkEnableOption;
    inherit (jackpkgsInputs.flake-parts.lib) mkDeferredModuleOption;
  in {
    jackpkgs.images = {
      enable = mkEnableOption "jackpkgs-images (standardized nix2container image building)" // {default = false;};

      linuxSystem = mkOption {
        type = types.str;
        default = "x86_64-linux";
        description = "The Linux system triple to build images for. Images are only built for this system.";
      };

      registry = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Default container registry URL (e.g. "ghcr.io/myorg/myrepo" or
          "us-east1-docker.pkg.dev/my-project/my-repo"). Per-image `registry`
          options override this. Required when enabled if not set per-image.
        '';
      };

      authMode = mkOption {
        type = types.str;
        default = "gcp";
        description = ''
          Authentication mode for `image-push` just recipe.
          Currently supported values:
          - "gcp": uses `gcloud auth print-access-token` + oauth2accesstoken
          - "ghcr": uses `GITHUB_ACTOR` + `GITHUB_TOKEN` env vars
          The type is `types.str` (not a fixed enum) so future auth modes
          ("op", "raw", etc.) can be added without a module schema change.
        '';
      };
    };

    perSystem = mkDeferredModuleOption ({
      config,
      lib,
      pkgs,
      ...
    }: {
      options.jackpkgs.images = {
        commonPackages = mkOption {
          type = types.listOf types.package;
          default = with pkgs; [bashInteractive cacert coreutils iana-etc];
          defaultText = lib.literalExpression "[ pkgs.bashInteractive pkgs.cacert pkgs.coreutils pkgs.iana-etc ]";
          description = ''
            Packages included in the shared common layer of every image.
            These are combined into a single buildEnv and emitted as one layer,
            so they are stored only once in the registry.
          '';
        };

        images = mkOption {
          type = types.attrsOf (types.submodule ({name, ...}: {
            options = {
              name = mkOption {
                type = types.str;
                default = name;
                description = "Image name. Defaults to the attribute key name.";
              };

              packages = mkOption {
                type = types.listOf types.package;
                default = [];
                description = "Per-image packages added as individual layers (after the common layer).";
              };

              entrypoint = mkOption {
                type = types.listOf types.str;
                default = [];
                description = "OCI entrypoint (e.g. [\"/bin/my-app\"]).";
              };

              cmd = mkOption {
                type = types.nullOr (types.listOf types.str);
                default = null;
                description = "OCI cmd (default command arguments).";
              };

              env = mkOption {
                type = types.listOf types.str;
                default = [];
                description = "OCI environment variables in KEY=VAL format. SSL_CERT_FILE is injected automatically.";
              };

              workingDir = mkOption {
                type = types.str;
                default = "/workspace";
                description = "Working directory inside the container.";
              };

              tag = mkOption {
                type = types.str;
                default = "latest";
                description = "Default tag for the image.";
              };

              extraLayers = mkOption {
                type = types.listOf types.unspecified;
                default = [];
                description = ''
                  Raw nix2container layers to append (escape hatch for custom
                  layering strategies like busybox /bin/sh for Cloud Run).
                '';
              };

              registry = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = "Per-image registry override. Falls back to jackpkgs.images.registry.";
              };
            };
          }));
          default = {};
          description = "Container images to build. Each key becomes an image in flake.images.<key>.";
        };
      };
    });
  };

  config = mkIf cfg.enable {
    # Per-system config: just recipes and skopeo package — Linux-only, since
    # nix2container and skopeo-nix2container are Linux binaries.
    perSystem = {
      pkgs,
      lib,
      config,
      system,
      ...
    }: let
      sysCfg = config.jackpkgs.images;
      nix2container = jackpkgsInputs.nix2container.packages.${cfg.linuxSystem}.nix2container;
      skopeoNix2container = jackpkgsInputs.nix2container.packages.${cfg.linuxSystem}.skopeo-nix2container;

      imageNames = lib.attrNames sysCfg.images;

      # Resolve registry for a given image config key
      resolveRegistry = imageKey: let
        imageCfg = sysCfg.images.${imageKey};
      in
        if imageCfg.registry != null
        then imageCfg.registry
        else if cfg.registry != null
        then cfg.registry
        else throw "jackpkgs.images: registry must be set either globally (jackpkgs.images.registry) or per-image (jackpkgs.images.images.<name>.registry)";

      # Auth credential derivation based on authMode
      credsExpr =
        if cfg.authMode == "gcp"
        then "\"oauth2accesstoken:$(gcloud auth print-access-token)\""
        else "\"\${GITHUB_ACTOR}:\${GITHUB_TOKEN}\"";

      imageBuildRecipe = mkRecipeWithParams "image-build" [''name''] "Build a container image locally (produces ./result JSON manifest)" [
        "nix build .#images.{{name}}"
      ] false;

      imageDigestRecipe = mkRecipeWithParams "image-digest" [''name''] "Show the SHA256 digest of a locally-built image" [
        "#!/usr/bin/env bash"
        "set -euo pipefail"
        "nix build .#images.{{name}}"
        "${lib.getExe skopeoNix2container} inspect nix:./result | ${lib.getExe pkgs.jq} -r '.Digest'"
      ] false;

      imagePushRecipe = mkRecipeWithParams "image-push" [''name'' ''tag=\"latest\"''] "Push a single image to its configured registry" (
        [
          "#!/usr/bin/env bash"
          "set -euo pipefail"
          "nix build .#images.{{name}}"
          "case \"{{name}}\" in"
        ]
        ++ lib.concatMap (imgKey: let
          imgCfg = sysCfg.images.${imgKey};
          reg = resolveRegistry imgKey;
        in [
          "  ${imgKey})"
          "    DEST=\"${reg}/${imgCfg.name}:{{tag}}\""
          "    ;;"
        ])
        imageNames
        ++ [
          "  *)"
          "    echo \"error: unknown image '{{name}}'\" >&2"
          "    exit 1"
          "    ;;"
          "esac"
          "CREDS=${credsExpr}"
          "${lib.getExe skopeoNix2container} copy --dest-creds \"$CREDS\" nix:./result \"docker://$DEST\""
        ]
      ) false;

      imagePushAllRecipe = mkRecipeWithParams "image-push-all" [''tag=\"latest\"''] "Push all images defined in jackpkgs.images.images" (
        [
          "#!/usr/bin/env bash"
          "set -euo pipefail"
        ]
        ++ map (imgName: "just image-push ${imgName} {{tag}}") imageNames
      ) false;
    in mkIf (system == cfg.linuxSystem) {
      # Expose skopeo-nix2container for direct use
      packages.skopeo-nix2container = skopeoNix2container;

      just-flake = {
        features.images = {
          enable = true;
          justfile = lib.concatStringsSep "\n\n" (
            [imageBuildRecipe imageDigestRecipe]
            ++ lib.optional (imageNames != []) imagePushRecipe
            ++ lib.optional (imageNames != []) imagePushAllRecipe
          );
        };
      };
    };

    # Top-level flake.images output — images are Linux-only, NOT perSystem packages.
    # Use getSystem to access the perSystem config for linuxSystem.
    flake.images = let
      linuxSysCfg = (getSystem cfg.linuxSystem).jackpkgs.images;
      nix2container = jackpkgsInputs.nix2container.packages.${cfg.linuxSystem}.nix2container;
      linuxPkgs = jackpkgsInputs.nixpkgs.legacyPackages.${cfg.linuxSystem};
    in
      builtins.mapAttrs (imageName: imageCfg: let
        # Build common layer from commonPackages
        commonLayer =
          if linuxSysCfg.commonPackages != []
          then
            nix2container.buildLayer {
              copyToRoot = linuxPkgs.buildEnv {
                name = "common-env";
                paths = linuxSysCfg.commonPackages;
              };
            }
          else null;

        baseLayers =
          if commonLayer != null
          then [commonLayer]
          else [];

        # Fold per-image packages into layers, deduplicating against common layer
        imageLayers = foldImageLayers nix2container baseLayers imageCfg.packages;

        # Inject SSL_CERT_FILE automatically
        sslEnv = "SSL_CERT_FILE=${linuxPkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
        imageEnv = imageCfg.env ++ [sslEnv];
      in
        nix2container.buildImage {
          name = imageCfg.name;
          tag = imageCfg.tag;
          layers = imageLayers ++ imageCfg.extraLayers;
          config = {
            Entrypoint = imageCfg.entrypoint;
            Cmd = imageCfg.cmd;
            Env = imageEnv;
            WorkingDir = imageCfg.workingDir;
          };
        })
      linuxSysCfg.images;
  };
}
