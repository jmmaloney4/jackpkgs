{inputs, ...}: {
  flake = {
    flakeModules = {
      default = import ./all.nix;
      just = import ./just.nix;
    };
  };
}
