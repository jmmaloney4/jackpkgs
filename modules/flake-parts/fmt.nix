{jackpkgsInputs}: {
  inputs,
  config,
  lib,
  ...
}: let
  inherit (lib) mkIf;
  inherit (jackpkgsInputs.self.lib) defaultExcludes;
  cfg = config.jackpkgs.fmt;
in {
  imports = [
    jackpkgsInputs.flake-root.flakeModule
    jackpkgsInputs.treefmt.flakeModule
  ];

  options = let
    inherit (lib) types mkOption mkEnableOption;
    inherit (jackpkgsInputs.flake-parts.lib) mkDeferredModuleOption;
  in {
    jackpkgs.fmt = {
      enable = mkEnableOption "jackpkgs-treefmt" // {default = true;};
    };

    perSystem = mkDeferredModuleOption ({
      config,
      lib,
      pkgs,
      ...
    }: {
      options.jackpkgs.fmt = {
        treefmtPackage = mkOption {
          type = types.package;
          default = config.jackpkgs.pkgs.treefmt;
          defaultText = "config.jackpkgs.pkgs.treefmt";
          description = "treefmt package to use.";
        };
        projectRootFile = mkOption {
          type = types.str;
          default = config.flake-root.projectRootFile;
          defaultText = "config.flake-root.projectRootFile";
          description = "Project root file to use.";
        };
        excludes = mkOption {
          type = types.listOf types.str;
          default = defaultExcludes.treefmt;
          description = "Excludes for treefmt. User-provided excludes will be appended to the defaults.";
        };

        # nbqa options for formatting Python code in notebooks
        nbqa = {
          enable = mkOption {
            type = types.bool;
            default = false;
            description = ''
              Enable nbqa-based formatting for Jupyter notebooks and Quarto files.
              Uses ruff to format and lint Python code within notebooks.
            '';
          };

          includes = mkOption {
            type = types.listOf types.str;
            default = ["*.ipynb" "*.qmd"];
            description = "File patterns to include for notebook formatting.";
          };

          nbqaPackage = mkOption {
            type = types.package;
            default = pkgs.nbqa;
            defaultText = "pkgs.nbqa";
            description = "nbqa package to use.";
          };

          ruffPackage = mkOption {
            type = types.nullOr types.package;
            default = pkgs.ruff;
            defaultText = "pkgs.ruff";
            description = ''
              Package providing ruff for notebook formatting.
              Set to null to use the ruff from your Python environment via ruffCommand.
            '';
          };

          ruffCommand = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = ''
              Custom ruff command path. Takes precedence over ruffPackage when set.
              Use this to specify a ruff from your Python environment, e.g.,
              "$\{config.packages.my-python-env}/bin/ruff".
            '';
          };

          ruffFormatOptions = mkOption {
            type = types.listOf types.str;
            default = [];
            description = ''
              Extra options to pass to ruff format.
              Example: ["--line-length=88" "--target-version=py312"]
            '';
            example = ["--line-length=88" "--target-version=py312"];
          };

          ruffCheckOptions = mkOption {
            type = types.listOf types.str;
            default = [];
            description = ''
              Extra options to pass to ruff check.
              Example: ["--line-length=88" "--target-version=py312" "--select=I,E,F"]
            '';
            example = ["--line-length=88" "--target-version=py312" "--select=I,E,F"];
          };
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
      sysCfg = config.jackpkgs.fmt;
      nbqaCfg = sysCfg.nbqa;

      # Determine ruff command path
      ruffCmd =
        if nbqaCfg.ruffCommand != null
        then nbqaCfg.ruffCommand
        else if nbqaCfg.ruffPackage != null
        then "${nbqaCfg.ruffPackage}/bin/ruff"
        else "ruff"; # fallback to PATH

      # Build nbqa formatter configurations
      nbqaFormatters = lib.optionalAttrs nbqaCfg.enable {
        # Jupyter notebooks - formatting with ruff format
        python-notebook-format = {
          command = "${nbqaCfg.nbqaPackage}/bin/nbqa";
          # Use nbqa in shell mode with pinned ruff path
          options = ["--nbqa-shell" "${ruffCmd} format"] ++ nbqaCfg.ruffFormatOptions ++ ["--"];
          includes = nbqaCfg.includes;
        };

        # Jupyter notebooks - linting with ruff check (includes import sorting)
        python-notebook-lint = {
          command = "${nbqaCfg.nbqaPackage}/bin/nbqa";
          # Shell mode avoids nbqa's import requirement for ruff
          options = ["--nbqa-shell" "${ruffCmd} check --fix"] ++ nbqaCfg.ruffCheckOptions ++ ["--"];
          includes = nbqaCfg.includes;
        };
      };
    in {
      formatter = lib.mkDefault config.treefmt.build.wrapper;
      treefmt.config = let
        excludes = lib.unique (defaultExcludes.treefmt ++ sysCfg.excludes);
      in {
        flakeFormatter = lib.mkForce false; # we set this ourselves above
        inherit (sysCfg) projectRootFile;
        package = sysCfg.treefmtPackage;

        ### Formatters ###
        # alejandra formats nix code
        programs.alejandra = {
          enable = true;
          inherit excludes;
        };
        # biome lints and formats js/ts code
        programs.biome = {
          enable = true;
          includes = ["**/*.ts" "**/*.tsx" "**/*.json" "**/*.jsonc" "**/*.json5"];
          inherit excludes;
        };
        programs.hujsonfmt = {
          enable = true;
          inherit excludes;
        };
        # latex
        programs.latexindent = {
          enable = true;
          inherit excludes;
        };
        # markdown
        programs.mdformat = {
          enable = true;
          inherit excludes;
          package = pkgs.mdformat;
          plugins = ps: [
            ps.mdformat-frontmatter
            ps.mdformat-gfm
            ps.mdformat-footnote
          ];
          settings = {
            end-of-line = "lf";
            number = true;
            wrap = "keep";
          };
        };
        # ruff lints and formats python code
        programs.ruff-check = {
          enable = true;
          inherit excludes;
        };
        programs.ruff-format = {
          enable = true;
          inherit excludes;
        };
        # rust obv
        programs.rustfmt = {
          enable = true;
          inherit excludes;
        };
        # toml
        programs.taplo = {
          enable = true;
          inherit excludes;
        };
        # yaml
        programs.yamlfmt = {
          enable = true;
          inherit excludes;
        };

        # Custom formatters (nbqa for notebooks)
        settings.formatter = nbqaFormatters;
      };
    };
  };
}
