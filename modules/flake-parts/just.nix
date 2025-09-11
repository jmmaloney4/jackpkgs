{inputs, config, ...}: {
  flake = {
    # Add the just flakeModule
    flakeModules.just = {
      perSystem = {
        system,
        pkgs,
        lib,
        ...
      }: {
        options = let
          inherit (lib) types mkOption mkEnableOption;
        in {
          enable = mkEnableOption "jackpkgs-just-flake";
        };

        config = let
          inherit (lib) mkIf;
        in
          mkIf config.just.enable {
            imports = [
              inputs.just-flake.flakeModules.just
            ];

            just-flake.features = {
              treefmt.enable = true;
              rust.enable = true;
              hello = {
                enable = true;
                justfile = ''
                  hello:
                  echo Hello Jackpkgs!
                '';
              };
            };
          };
      };
    };
  };
}
