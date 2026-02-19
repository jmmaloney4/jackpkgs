{jackpkgsInputs}: {
  config,
  lib,
  ...
}: {
  options = let
    inherit (lib) types mkOption;
  in {
    jackpkgs.gcp = {
      iamOrg = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "example.com";
        description = ''
          GCP IAM organization domain for constructing user accounts.
          When set, the auth recipe will use --account=$GCP_ACCOUNT_USER@$IAM_ORG
          where GCP_ACCOUNT_USER defaults to the current Unix username ($USER).
        '';
      };

      quotaProject = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "my-project-123";
        description = ''
          GCP project ID to use for Application Default Credentials quota/billing.
          When set, the auth recipe will call:
            gcloud auth application-default set-quota-project <quotaProject>
        '';
      };

      profile = mkOption {
        type = types.nullOr types.str;
        default = null;
        defaultText = "config.jackpkgs.gcp.iamOrg";
        description = ''
          Name of the gcloud profile directory under ~/.config/gcloud-profiles/.
          When set, CLOUDSDK_CONFIG is exported in the devshell to isolate gcloud
          credentials, ADC, and configuration per-project.
          Defaults to the value of jackpkgs.gcp.iamOrg when that option is set.
        '';
      };
    };
  };

  config = {
    jackpkgs.gcp.profile = lib.mkDefault config.jackpkgs.gcp.iamOrg;
  };
}
