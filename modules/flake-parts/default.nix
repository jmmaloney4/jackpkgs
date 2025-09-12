{
  config,
  inputs,
  ...
}: {
  flake = {
    flakeModule = import ./all.nix;
    flakeModules = {
      default = import ./all.nix;
      just = import ./just.nix;
    };
  };
}
