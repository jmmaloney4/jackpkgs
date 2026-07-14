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
        mdformat.validate = mkOption {
          type = types.bool;
          default = true;
          description = ''
            Whether mdformat should validate markdown after formatting.
            Set to false to disable validation (equivalent to --no-validate),
            which is useful for markdown files containing non-standard syntax
            such as LaTeX.
          '';
        };
        nbqa = {
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
              "${"$"}{config.packages.my-python-env}/bin/ruff".
            '';
          };
          ruffFormatOptions = mkOption {
            type = types.listOf types.str;
            default = [];
            description = ''Extra options to pass to ruff format.'';
            example = ["--line-length=88" "--target-version=py312"];
          };
          ipynb = {
            enable = mkOption {
              type = types.bool;
              default = false;
              description = ''Enable nbqa-based formatting for Jupyter `.ipynb` notebooks.'';
            };
            includes = mkOption {
              type = types.listOf types.str;
              default = ["*.ipynb"];
              description = ''File patterns to include for `.ipynb` notebook formatting.'';
            };
            nbqaPackage = mkOption {
              type = types.package;
              default = pkgs.nbqa;
              defaultText = "pkgs.nbqa";
              description = ''nbqa package to use for `.ipynb` formatting.'';
            };
          };
          myst = {
            enable = mkOption {
              type = types.bool;
              default = false;
              description = ''Enable jupytext-based formatting for MyST-NB markdown notebooks.'';
            };
            includes = mkOption {
              type = types.listOf types.str;
              default = [];
              description = ''File patterns to include for MyST-NB formatting. Users SHOULD configure explicitly.'';
              example = ["docs/**/*.md"];
            };
            jupytextPackage = mkOption {
              type = types.package;
              default = pkgs.python313Packages.jupytext;
              defaultText = "pkgs.python313Packages.jupytext";
              description = ''jupytext package to use for MyST-NB formatting.'';
            };
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
      lockfileExcludes = [
        "pnpm-lock.yaml"
        "**/pnpm-lock.yaml"
      ];
      nbqaCfg = sysCfg.nbqa;
      ruffCmd =
        if nbqaCfg.ruffCommand != null
        then nbqaCfg.ruffCommand
        else if nbqaCfg.ruffPackage != null
        then "${nbqaCfg.ruffPackage}/bin/ruff"
        else "ruff";
      notebookFormatters =
        lib.optionalAttrs nbqaCfg.ipynb.enable {
          python-notebook-format = {
            command = "${nbqaCfg.ipynb.nbqaPackage}/bin/nbqa";
            options = ["${ruffCmd} format" "--nbqa-shell"] ++ nbqaCfg.ruffFormatOptions ++ ["--"];
            includes = nbqaCfg.ipynb.includes;
          };
        }
        // lib.optionalAttrs nbqaCfg.myst.enable {
          python-myst-notebook-format = {
            command = "${nbqaCfg.myst.jupytextPackage}/bin/jupytext";
            options = ["--pipe" "${ruffCmd} format {}" "--pipe-fmt" "py:percent"];
            includes = nbqaCfg.myst.includes;
          };
        };
    in {
      formatter = lib.mkDefault config.treefmt.build.wrapper;
      treefmt.config = let
        excludes = lib.unique (defaultExcludes.treefmt ++ sysCfg.excludes ++ lockfileExcludes);
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
          # Include both bare patterns (for root-level files) and ** patterns
          # (for nested files). treefmt's ** glob requires at least one directory
          # separator, so root-level files like package.json are excluded without
          # the bare *.ext forms.
          includes = [
            "*.ts"
            "*.tsx"
            "*.json"
            "*.jsonc"
            "*.json5"
            "**/*.ts"
            "**/*.tsx"
            "**/*.json"
            "**/*.jsonc"
            "**/*.json5"
          ];
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
            ps.mdformat-myst
          ];
          settings = {
            end-of-line = "lf";
            number = true;
            wrap = "keep";
          };
        };
        settings.formatter =
          notebookFormatters
          // {
            mdformat.options = lib.mkAfter (
              lib.optional (!sysCfg.mdformat.validate) "--no-validate"
            );
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
        # shell formatting via shfmt
        programs.shfmt = {
          enable = true;
          inherit excludes;
          indent_size = 2;
          simplify = true;
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
      };
    };
  };
}
