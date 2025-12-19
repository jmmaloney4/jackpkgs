{jackpkgsInputs}: {
  inputs,
  config,
  lib,
  ...
}: let
  inherit (lib) mkIf;
  cfg = config.jackpkgs.pnpm;
in {
  imports = [
  ];

  options = let
    inherit (lib) types mkOption mkEnableOption;
    inherit (jackpkgsInputs.flake-parts.lib) mkDeferredModuleOption;
  in {
    jackpkgs.pnpm = {
      enable = mkEnableOption "jackpkgs-pnpm" // {default = true;};
    };

    perSystem = mkDeferredModuleOption ({
      config,
      lib,
      pkgs,
      ...
    }: {
      options.jackpkgs.pnpm.ci.packages = mkOption {
        type = with types; listOf package;
        default = with pkgs; [
          nodejs
          pnpm
          jq
        ];
        defaultText = lib.literalExpression ''
          with pkgs; [
            nodejs
            pnpm
            jq
          ]
        '';
        description = "Packages included in the ci-pnpm devshell";
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
        # CI devshell with minimal dependencies for pnpm operations
        devShells.ci-pnpm = pkgs.mkShell {
          packages = config.jackpkgs.pnpm.ci.packages;
        };
      };
    };
}
