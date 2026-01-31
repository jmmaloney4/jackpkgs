{jackpkgsInputs}: {
  inputs,
  config,
  lib,
  ...
}: let
  inherit (lib) mkIf attrByPath;
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
            pythonDefaultEnv =
              attrByPath ["jackpkgs" "outputs" "pythonDefaultEnv"] null config;
          in
            if pythonDefaultEnv != null
            then pythonDefaultEnv
            else config.jackpkgs.pkgs.mypy;
          defaultText = "`jackpkgs.python.environments.default` (when defined) or `config.jackpkgs.pkgs.mypy`";
          description = "mypy package to use.";
        };
        npmLockfileFixPackage = mkOption {
          type = types.package;
          default = let
            nodejsDevShell =
              attrByPath ["jackpkgs" "outputs" "nodejsDevShell"] null config;
          in
            if nodejsDevShell != null
            then
              # Extract npm-lockfile-fix from nodejs devshell if available
              pkgs.python3Packages.buildPythonApplication {
                pname = "npm-lockfile-fix";
                version = "0.1.1";
                pyproject = true;

                src = pkgs.fetchFromGitHub {
                  owner = "jeslie0";
                  repo = "npm-lockfile-fix";
                  rev = "v0.1.1";
                  hash = "sha256-P93OowrVkkOfX5XKsRsg0c4dZLVn2ZOonJazPmHdD7g=";
                };

                build-system = [pkgs.python3Packages.setuptools];
                propagatedBuildInputs = [pkgs.python3Packages.requests];

                meta = {
                  description = "Add missing integrity and resolved fields to npm workspace lockfiles";
                  homepage = "https://github.com/jeslie0/npm-lockfile-fix";
                  license = pkgs.lib.licenses.mit;
                };
              }
            else
              pkgs.python3Packages.buildPythonApplication {
                pname = "npm-lockfile-fix";
                version = "0.1.1";
                pyproject = true;

                src = pkgs.fetchFromGitHub {
                  owner = "jeslie0";
                  repo = "npm-lockfile-fix";
                  rev = "v0.1.1";
                  hash = "sha256-P93OowrVkkOfX5XKsRsg0c4dZLVn2ZOonJazPmHdD7g=";
                };

                build-system = [pkgs.python3Packages.setuptools];
                propagatedBuildInputs = [pkgs.python3Packages.requests];

                meta = {
                  description = "Add missing integrity and resolved fields to npm workspace lockfiles";
                  homepage = "https://github.com/jeslie0/npm-lockfile-fix";
                  license = pkgs.lib.licenses.mit;
                };
              };
          defaultText = "npm-lockfile-fix package from nodejs devshell or standalone";
          description = "npm-lockfile-fix package to use for validating workspace lockfiles.";
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
        settings.hooks.npm-lockfile-fix = {
          enable = lib.mkDefault (attrByPath ["jackpkgs" "nodejs" "enable"] false config);
          package = sysCfg.npmLockfileFixPackage;
          entry = "${lib.getExe sysCfg.npmLockfileFixPackage}";
          files = "package-lock\\.json$";
          pass_filenames = true;
          description = "Fix npm workspace lockfiles for Nix compatibility (adds missing resolved/integrity fields)";
        };
      };
    };
  };
}
