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
          ];
          settings = {
            end-of-line = "lf";
            number = true;
            wrap = "keep";
          };
        };
        settings.formatter.mdformat.options = lib.mkAfter (
          lib.optional (!sysCfg.mdformat.validate) "--no-validate"
        );
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
