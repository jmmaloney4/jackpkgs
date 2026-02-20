{jackpkgsInputs}: {
  inputs,
  config,
  lib,
  ...
}: let
  inherit (lib) mkIf;
  inherit (jackpkgsInputs.self.lib) defaultExcludes;
  cfg = config.jackpkgs.pre-commit;
in {
  imports = [
    jackpkgsInputs.pre-commit-hooks.flakeModule
  ];

  options = let
    inherit (lib) types mkOption mkEnableOption;
    inherit (jackpkgsInputs.flake-parts.lib) mkDeferredModuleOption;
  in {
    jackpkgs.pre-commit = {
      enable = mkEnableOption "jackpkgs-pre-commit" // {default = true;};
    };

    perSystem = mkDeferredModuleOption ({
      config,
      lib,
      pkgs,
      pythonWorkspace ? null,
      ...
    }: {
      options.jackpkgs.pre-commit = {
        treefmtPackage = mkOption {
          type = types.package;
          default = config.treefmt.build.wrapper;
          defaultText = "config.treefmt.build.wrapper";
          description = "treefmt package to use.";
        };
        nbstripoutPackage = mkOption {
          type = types.package;
          default = config.jackpkgs.pkgs.nbstripout;
          defaultText = "config.jackpkgs.pkgs.nbstripout";
          description = "nbstripout package to use.";
        };
        mypyPackage = mkOption {
          type = types.package;
          default = let
            pythonCfg = config.jackpkgs.python or {};
            configuredEnvs = pythonCfg.environments or {};
            pythonEnvOutputs = config.jackpkgs.outputs.pythonEnvironments or {};

            isEditableEnv = envCfg: envCfg != null && (envCfg.editable or false);
            isNonEditableEnv = envCfg: envCfg != null && !isEditableEnv envCfg;
            isCiEnvCandidate = envCfg:
              isNonEditableEnv envCfg
              && (envCfg.includeGroups or null) == true;

            hasDevEnv = configuredEnvs ? dev;
            devEnvConfig = configuredEnvs.dev or null;

            envWithGroups =
              lib.findFirst
              (envName: isCiEnvCandidate (configuredEnvs.${envName} or null))
              null
              (lib.attrNames configuredEnvs);

            selectedEnv =
              if hasDevEnv && isCiEnvCandidate devEnvConfig
              then pythonEnvOutputs.dev or null
              else if envWithGroups != null
              then pythonEnvOutputs.${envWithGroups} or null
              else null;

            pythonEnvWithDevTools =
              if selectedEnv != null
              then selectedEnv
              else if pythonWorkspace != null
              then
                pythonWorkspace.mkEnv {
                  name = "python-ci-checks";
                  spec = pythonWorkspace.computeSpec {
                    includeGroups = true;
                  };
                }
              else null;

            pythonDefaultEnv =
              config.jackpkgs.outputs.pythonDefaultEnv or null;
          in
            if pythonEnvWithDevTools != null
            then pythonEnvWithDevTools
            else if pythonDefaultEnv != null
            then pythonDefaultEnv
            else config.jackpkgs.pkgs.mypy;
          defaultText = ''
            Dev-tools Python env (same precedence as `checks.nix`):
            1. `jackpkgs.python.environments.dev` if non-editable and `includeGroups = true`
            2. Any non-editable `jackpkgs.python.environments.*` with `includeGroups = true`
            3. Auto-created env with `includeGroups = true` (via `pythonWorkspace`)
            4. `jackpkgs.python.environments.default` (when defined)
            5. `config.jackpkgs.pkgs.mypy`
          '';
          description = ''
            mypy package (or Python environment containing mypy) to use for the
            pre-commit mypy hook.

            Defaults to the same dev-tools environment selection used by
            `checks.nix` CI checks, preferring a non-editable environment with
            dependency groups enabled (e.g. `jackpkgs.python.environments.dev`
            with `includeGroups = true`). This ensures pre-commit mypy sees the
            same dependencies as CI.
          '';
        };
      };
    });
  };

  config = mkIf cfg.enable {
    perSystem = {
      pkgs,
      lib,
      config,
      ...
    }: let
      sysCfg = config.jackpkgs.pre-commit;
    in {
      pre-commit = {
        check.enable = true;
        settings.hooks.treefmt.enable = true;
        settings.hooks.treefmt.package = sysCfg.treefmtPackage;
        settings.hooks.nbstripout = {
          enable = true;
          package = sysCfg.nbstripoutPackage;
          entry = "${lib.getExe sysCfg.nbstripoutPackage}";
          files = "\\.ipynb$";
        };
        settings.hooks.mypy = {
          enable = true;
          package = sysCfg.mypyPackage;
          entry = lib.getExe' sysCfg.mypyPackage "mypy";
          files = "\\.py$";
          excludes = defaultExcludes.preCommit;
        };
      };
    };
  };
}
