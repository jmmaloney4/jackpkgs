{
  config,
  inputs,
  ...
}: {
  flake = {
    flakeModule = import ./all.nix;
    flakeModules = {
      default = import ./all.nix;

      # Don't forget to update all.nix too!
      just = import ./just.nix;
      pre-commit = import ./pre-commit.nix;
    };
  };
}
