{
  inputs,
  config,
  lib,
  ...
}: let
  inherit (lib) mkIf;
  cfg = config.jackpkgs.just; # top-level enable
in {
  imports = [
    inputs.just-flake.flakeModule
  ];

  options = let
    inherit (lib) types mkOption mkEnableOption;
    inherit (inputs.flake-parts.lib) mkDeferredModuleOption;
  in {
    jackpkgs.just = {
      enable = mkEnableOption "jackpkgs-just-flake" // {default = true;};
    };

    perSystem = mkDeferredModuleOption ({
      lib,
      pkgs,
      ...
    }: {
      options.jackpkgs.just = {
        pulumiPackage = mkOption {
          type = types.package;
          default = pkgs.pulumi;
          defaultText = "pkgs.pulumi";
          description = "Pulumi package to use.";
        };
        nbstripoutPackage = mkOption {
          type = types.package;
          default = pkgs.nbstripout;
          defaultText = "pkgs.nbstripout";
          description = "Nbstripout package to use.";
        };
        fdPackage = mkOption {
          type = types.package;
          default = pkgs.fd;
          defaultText = "pkgs.fd";
          description = "fd package to use for finding files.";
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
          rust.enable = true;
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
        };
      };
    };
  };
}
