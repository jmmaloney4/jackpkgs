{jackpkgsInputs}: {
  inputs,
  config,
  lib,
  ...
}: let
  inherit (lib) mkIf;
  cfg = config.jackpkgs.pulumi;
in {
  imports = [
  ];

  options = let
    inherit (lib) types mkOption mkEnableOption;
    inherit (jackpkgsInputs.flake-parts.lib) mkDeferredModuleOption;
  in {
    jackpkgs.pulumi = {
      enable = mkEnableOption "jackpkgs-pulumi" // {default = true;};
    };

    perSystem = mkDeferredModuleOption ({
      config,
      lib,
      pkgs,
      ...
    }: {
      options.jackpkgs.outputs.pulumiDevShell = mkOption {
        type = types.package;
        readOnly = true;
        description = "Pulumi devShell fragment to include in `inputsFrom`.";
      };
    });
  };

  config = mkIf cfg.enable {
    perSystem = {
      pkgs,
      lib,
      config,
      ...
    }: {
      jackpkgs.outputs.pulumiDevShell = pkgs.mkShell {
        packages = [
          pkgs.pulumi
        ];
      };
    };
  };
}
