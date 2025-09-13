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
      fmt = import ./fmt.nix {jackpkgsInputs = inputs;};
      just = import ./just.nix {jackpkgsInputs = inputs;};
      pre-commit = import ./pre-commit.nix {jackpkgsInputs = inputs;};
    };
  };
}
