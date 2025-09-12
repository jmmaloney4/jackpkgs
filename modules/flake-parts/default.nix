{config, inputs, ...}: {
  flake = {
    flakeModule = config.flakeModules.default;
    flakeModules = {
      default = import ./all.nix;
      just = import ./just.nix;
    };
  };
}
