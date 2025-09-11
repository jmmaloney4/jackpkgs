{inputs, ...}: {
  flake = {
    # Add the just flakeModule
    flakeModules.just = import ./just.nix;
  };
}
