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
  foldImageLayers = nix2container: baseLayers: pkgList: let
    # acc holds layers in reverse order; we reverse at the end.
    # We reverse baseLayers so they also sit in the reversed accumulator.
    init = lib.reverseList baseLayers;
    fold = acc: drv: let
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

      labels = mkOption {
        type = types.attrsOf types.str;
        default = {};
        example = lib.literalExpression ''
          { "org.opencontainers.image.source" = "https://github.com/OWNER/REPO"; }
        '';
        description = ''
          OCI labels merged into every image's config.Labels. Per-image
          `labels` take precedence on key collisions. Set the standard
          "org.opencontainers.image.source" here once to link all images to
          the GitHub repository.
        '';
      };

      addRevisionLabel = mkOption {
        type = types.bool;
        default = true;
        description = ''
          When true (the default), inject "org.opencontainers.image.revision"
          into every image, derived from the CONSUMER flake's git revision via
          `self.dirtyRev or self.rev`: a clean tree yields the commit SHA, a
          dirty tree yields "<sha>-dirty", and a source with no git info
          (e.g. a tarball) omits the label rather than emitting a placeholder.
          A per-image or global `labels` entry for the same key overrides it.
          NOTE: this makes each image's hash change per commit, which is the
          point (traceability) but means images rebuild every commit. Set false
          to opt out (e.g. for reproducible-by-content builds).
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
          type = types.attrsOf (types.submodule ({
            name,
            config,
            ...
          }: {
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
                description = ''
                  OCI environment variables in KEY=VAL format. SSL_CERT_FILE is
                  injected automatically (suppressed for a fromImage build with no
                  explicit env, where it would otherwise clobber the base env).
                  NOTE: for a fromImage build, setting env REPLACES the base
                  image's entire environment (nix2container does not merge), so
                  include any base vars (PATH/HOME/...) you still need.
                '';
              };

              workingDir = mkOption {
                type = types.nullOr types.str;
                # Inherit the base's workingDir by default for fromImage builds
                # (null -> omitted); from-scratch images keep /workspace.
                default =
                  if config.fromImage != null
                  then null
                  else "/workspace";
                defaultText = lib.literalExpression ''if fromImage != null then null else "/workspace"'';
                description = "Working directory inside the container. null omits it (inherit from a fromImage base).";
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

              labels = mkOption {
                type = types.attrsOf types.str;
                default = {};
                example = lib.literalExpression ''
                  { "org.opencontainers.image.source" = "https://github.com/OWNER/REPO"; }
                '';
                description = ''
                  OCI image labels (config.Labels), e.g. setting
                  "org.opencontainers.image.source" to link the image to its
                  GitHub repository. For a fromImage build, nix2container MERGES
                  these with the base image's labels (unlike env, which it
                  replaces), so the base's labels are preserved.
                '';
              };

              registry = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = "Per-image registry override. Falls back to jackpkgs.images.registry.";
              };

              fromImage = mkOption {
                type = types.nullOr types.unspecified;
                default = null;
                description = ''
                  Base image to build on top of — the output of
                  `nix2container.pullImage`. null (default) builds from scratch.
                  When set, the image's `packages`/`extraLayers` are layered onto
                  the base, and config fields left at their empty/null value
                  (entrypoint = [], env = [], cmd = null, workingDir = null) are
                  omitted so the base image's own entrypoint/env/workingDir are
                  inherited rather than clobbered.
                '';
              };

              skipCommonLayer = mkOption {
                type = types.bool;
                # Default: skip for fromImage builds (the base typically already
                # provides bash/coreutils/certs, and prepending ours would shadow
                # the base's userland and cert paths) and keep for from-scratch.
                # Override explicitly, e.g. set false for a distroless fromImage
                # base that genuinely needs the shared userland layer.
                default = config.fromImage != null;
                defaultText = lib.literalExpression "fromImage != null";
                description = ''
                  Skip the shared commonPackages layer for this image. Defaults to
                  true for fromImage builds, false otherwise. When skipped,
                  SSL_CERT_FILE is not derived from commonPackages (only from this
                  image's own `packages`).
                '';
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
        else if cfg.authMode == "ghcr"
        then "\"\${GITHUB_ACTOR}:\${GITHUB_TOKEN}\""
        else abort "jackpkgs.images: unsupported authMode '${cfg.authMode}'";

      imageBuildRecipe =
        mkRecipeWithParams "image-build" [''name''] "Build a container image locally (produces ./result JSON manifest)" [
          "nix build .#images.{{name}}"
        ]
        false;

      imageDigestRecipe =
        mkRecipeWithParams "image-digest" [''name''] "Show the SHA256 digest of a locally-built image" [
          "#!/usr/bin/env bash"
          "set -euo pipefail"
          "nix build .#images.{{name}}"
          "${lib.getExe skopeoNix2container} inspect nix:./result | ${lib.getExe pkgs.jq} -r '.Digest'"
        ]
        false;

      imagePushRecipe =
        mkRecipeWithParams "image-push" [''name'' ''tag="latest"''] "Push a single image to its configured registry" (
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
        )
        false;

      imagePushAllRecipe =
        mkRecipeWithParams "image-push-all" [''tag="latest"''] "Push all images defined in jackpkgs.images.images" (
          [
            "#!/usr/bin/env bash"
            "set -euo pipefail"
          ]
          ++ map (imgName: "just image-push ${imgName} {{tag}}") imageNames
        )
        false;
    in
      mkIf (system == cfg.linuxSystem) {
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

      # Git revision of the CONSUMER flake (inputs.self here is the flake that
      # imports this module, not jackpkgs). Clean tree -> rev (sha); dirty tree
      # -> dirtyRev ("<sha>-dirty"); no git info (tarball/path) -> null. `or`
      # swallows the missing-attr case in each step.
      revisionLabels = lib.optionalAttrs cfg.addRevisionLabel (
        let
          revision = inputs.self.dirtyRev or inputs.self.rev or null;
        in
          lib.optionalAttrs (revision != null) {
            "org.opencontainers.image.revision" = revision;
          }
      );
    in
      builtins.mapAttrs (imageName: imageCfg: let
        # Build common layer from commonPackages, unless the image opts out via
        # skipCommonLayer. Kept by default (including for fromImage), so distroless
        # or otherwise-minimal bases still get the shared userland. Opt out for a
        # base that already provides bash/coreutils/certs (e.g. linuxserver), where
        # adding ours is redundant and would shadow the base's userland.
        commonLayer =
          if linuxSysCfg.commonPackages != [] && !imageCfg.skipCommonLayer
          then
            nix2container.buildLayer {
              copyToRoot = linuxPkgs.buildEnv {
                name = "common-env";
                paths = linuxSysCfg.commonPackages;
                # Python packages (e.g. dbt-bigquery and dbt-core) may ship identical
                # files under different store paths. Container images are isolated
                # environments, so duplicate content is harmless.
                ignoreCollisions = true;
              };
            }
          else null;

        baseLayers =
          if commonLayer != null
          then [commonLayer]
          else [];

        # Fold per-image packages into layers, deduplicating against common layer
        imageLayers = foldImageLayers nix2container baseLayers imageCfg.packages;

        # Inject SSL_CERT_FILE from a cacert that is ACTUALLY in the image: scan
        # commonPackages only when the common layer is present (not opted out), so a
        # skipCommonLayer build never points SSL_CERT_FILE at an absent cert path.
        cacertPkg =
          lib.findFirst
          (p: lib.isAttrs p && lib.elem (p.pname or "") ["nss-cacert" "cacert"])
          null
          (imageCfg.packages
            ++ lib.optionals (!imageCfg.skipCommonLayer) linuxSysCfg.commonPackages);
        # Don't auto-inject SSL_CERT_FILE into a fromImage build that has no
        # explicit env: nix2container replaces (not merges) config.Env against the
        # base, so a lone SSL_CERT_FILE would wipe the base's own PATH/HOME/etc.
        # The base brings its own certs.
        shouldInjectSslEnv =
          cacertPkg
          != null
          && !(imageCfg.fromImage != null && imageCfg.env == []);
        sslEnv =
          lib.optional shouldInjectSslEnv
          "SSL_CERT_FILE=${cacertPkg}/etc/ssl/certs/ca-bundle.crt";
        imageEnv = imageCfg.env ++ sslEnv;

        # Merge label sources by ascending precedence: auto-derived revision <
        # global jackpkgs.images.labels < per-image labels. Omitted from the
        # config entirely when the result is empty, so a fromImage base's own
        # labels are preserved (nix2container merges Labels with the base).
        mergedLabels = revisionLabels // cfg.labels // imageCfg.labels;

        # OCI config, omitting fields left at their empty/null value so a fromImage
        # base's own entrypoint/env/workingDir are inherited rather than clobbered.
        # For from-scratch images, omitting an empty field is equivalent to setting
        # it empty, so existing images are unaffected.
        imageConfig =
          (lib.optionalAttrs (imageCfg.entrypoint != []) {Entrypoint = imageCfg.entrypoint;})
          // (lib.optionalAttrs (imageCfg.cmd != null) {Cmd = imageCfg.cmd;})
          // (lib.optionalAttrs (imageEnv != []) {Env = imageEnv;})
          // (lib.optionalAttrs (imageCfg.workingDir != null) {WorkingDir = imageCfg.workingDir;})
          // (lib.optionalAttrs (mergedLabels != {}) {Labels = mergedLabels;});
      in
        nix2container.buildImage ({
            name = imageCfg.name;
            tag = imageCfg.tag;
            layers = imageLayers ++ imageCfg.extraLayers;
            config = imageConfig;
          }
          // lib.optionalAttrs (imageCfg.fromImage != null) {
            inherit (imageCfg) fromImage;
          }))
      linuxSysCfg.images;
  };
}
