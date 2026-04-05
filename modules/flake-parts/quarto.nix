{jackpkgsInputs}: {
  inputs,
  config,
  lib,
  ...
}: let
  flakeConfig = config;
  inherit (lib) mkIf;
  cfg = config.jackpkgs.quarto;
in {
  imports = [
  ];

  options = let
    inherit (lib) types mkOption mkEnableOption;
    inherit (jackpkgsInputs.flake-parts.lib) mkDeferredModuleOption;
  in {
    jackpkgs.quarto = {
      enable = mkEnableOption "jackpkgs-quarto" // {default = true;};

      sites = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Quarto sites to build.";
      };
    };

    perSystem = mkDeferredModuleOption ({
      config,
      lib,
      pkgs,
      ...
    }: {
      options.jackpkgs.outputs.quartoDevShell = mkOption {
        type = types.package;
        readOnly = true;
        description = "Quarto devShell fragment to include in `inputsFrom`.";
      };

      options.jackpkgs.quarto = {
        quartoPackage = mkOption {
          type = types.package;
          default = let
            base = config.jackpkgs.pkgs.quarto;
            jupyterCfg = flakeConfig.jackpkgs.jupyter;
            jupyterPkg = config.packages.${jupyterCfg.packageName};
          in
            if jupyterCfg.enable
            then
              pkgs.runCommand "quarto-wrapped" {
                nativeBuildInputs = [pkgs.makeWrapper];
                meta.mainProgram = "quarto";
              } ''
                mkdir -p $out/bin
                makeWrapper ${base}/bin/quarto $out/bin/quarto \
                  --prefix JUPYTER_PATH : "${jupyterPkg}/share/jupyter" \
                  --set QUARTO_PYTHON "${config.jackpkgs.quarto.pythonEnv}/bin/python"
              ''
            else base;
          defaultText = "config.jackpkgs.pkgs.quarto (wrapped with Jupyter if enabled)";
          description = "Quarto package to use.";
        };

        pythonEnv = mkOption {
          type = types.package;
          default = config.jackpkgs.pkgs.python3Packages.python;
          defaultText = "config.jackpkgs.pkgs.python3Packages.python";
          description = "Python environment to use for Quarto.";
        };
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
        jackpkgs.outputs.quartoDevShell = pkgs.mkShell {
          packages = with pkgs; [
          ];
        };

        # Contribute this fragment to the composed devshell
        jackpkgs.shell.inputsFrom = [
          config.jackpkgs.outputs.quartoDevShell
        ];
      };
    };
}
