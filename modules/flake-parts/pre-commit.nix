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
            pythonWorkspace = config._module.args.pythonWorkspace or null;
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

        numpydocEnable = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Enable the pre-commit numpydoc docstring validation hook.

            Requires `numpydoc` to be available in `numpydocPackage`.
          '';
        };

        numpydocPackage = mkOption {
          type = types.package;
          default = config.jackpkgs.pre-commit.mypyPackage;
          defaultText = "config.jackpkgs.pre-commit.mypyPackage";
          description = ''
            Python package (or Python environment) that provides `python -m
            numpydoc.hooks.validate_docstrings` for the pre-commit numpydoc
            hook.
          '';
        };

        numpydocExtraArgs = mkOption {
          type = types.listOf types.str;
          default = [];
          description = "Extra arguments passed to numpydoc.hooks.validate_docstrings.";
          example = ["--checks" "all"];
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
        settings.hooks.numpydoc = {
          enable = sysCfg.numpydocEnable;
          package = sysCfg.numpydocPackage;
          entry = let
            pythonExe = lib.getExe' sysCfg.numpydocPackage "python";
          in "${pythonExe} -m numpydoc.hooks.validate_docstrings${lib.optionalString (sysCfg.numpydocExtraArgs != []) " ${lib.escapeShellArgs sysCfg.numpydocExtraArgs}"}";
          files = "\\.py$";
          excludes = defaultExcludes.preCommit;
        };
      };
    };
  };
}
