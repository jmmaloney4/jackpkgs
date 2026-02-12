{jackpkgsInputs}: {
  inputs,
  config,
  lib,
  ...
}: let
  inherit (lib) mkIf;
  cfg = config.jackpkgs.pulumi;
in {
  imports = [
  ];

  options = let
    inherit (lib) types mkOption mkEnableOption;
    inherit (jackpkgsInputs.flake-parts.lib) mkDeferredModuleOption;
  in {
    jackpkgs.pulumi = {
      enable = mkEnableOption "jackpkgs-pulumi" // {default = true;};

      backendUrl = mkOption {
        type = types.str;
        description = "Pulumi backend URL to use for authentication and stack operations. Required when enable is true.";
      };

      secretsProvider = mkOption {
        type = types.str;
        description = "Pulumi secrets provider to use for authentication and stack operations. Required when enable is true.";
      };
    };

    perSystem = mkDeferredModuleOption ({
      config,
      lib,
      pkgs,
      ...
    }: {
      options.jackpkgs.outputs.pulumiDevShell = mkOption {
        type = types.package;
        readOnly = true;
        description = "Pulumi devShell fragment to include in `inputsFrom`.";
      };

      options.jackpkgs.pulumi.ci.packages = mkOption {
        type = with types; listOf package;
        default = with config.jackpkgs.pkgs; [
          pulumi-bin
          nodejs
          jq
          (google-cloud-sdk.withExtraComponents [google-cloud-sdk.components.gke-gcloud-auth-plugin])
        ];
        defaultText = lib.literalExpression ''
          with config.jackpkgs.pkgs; [
            pulumi-bin
            nodejs
            jq
            (google-cloud-sdk.withExtraComponents [google-cloud-sdk.components.gke-gcloud-auth-plugin])
          ]
        '';
        description = "Packages included in the ci-pulumi devshell";
      };
    });
  };

  config =
    mkIf cfg.enable
    {
      perSystem = {
        pkgs,
        lib,
        config,
        ...
      }: {
        jackpkgs.outputs.pulumiDevShell = pkgs.mkShell {
          packages = with pkgs; [
            pulumi-bin
            nodejs
            jq
            just
            (google-cloud-sdk.withExtraComponents [google-cloud-sdk.components.gke-gcloud-auth-plugin])
            nodePackages.typescript
          ];
          env = {
            # Disable discovering additional plugins by examining $PATH.
            # Pulumi will download the relevant plugin versions instead.
            PULUMI_IGNORE_AMBIENT_PLUGINS = "1";
            # Export configured backend and secrets provider
            PULUMI_BACKEND_URL = cfg.backendUrl;
            PULUMI_SECRETS_PROVIDER = cfg.secretsProvider;
          };
        };

        # CI devshell with minimal dependencies for running Pulumi in CI
        devShells.ci-pulumi = pkgs.mkShell {
          packages = config.jackpkgs.pulumi.ci.packages;

          env = {
            # Disable discovering additional plugins by examining $PATH.
            # Pulumi will download the relevant plugin versions instead.
            PULUMI_IGNORE_AMBIENT_PLUGINS = "1";
            # Export configured backend and secrets provider
            PULUMI_BACKEND_URL = cfg.backendUrl;
            PULUMI_SECRETS_PROVIDER = cfg.secretsProvider;
          };
        };

        # Contribute this fragment to the composed devshell
        jackpkgs.shell.inputsFrom = [
          config.jackpkgs.outputs.pulumiDevShell
        ];
      };
    };
}
