{
  config,
  inputs,
  ...
}: {
  flake = {
    flakeModule = import ./all.nix {jackpkgsInputs = inputs;};
    flakeModules = {
      default = import ./all.nix {jackpkgsInputs = inputs;};

      # Don't forget to update all.nix too!
      fmt = import ./fmt.nix {jackpkgsInputs = inputs;};
      just = import ./just.nix {jackpkgsInputs = inputs;};
      pre-commit = import ./pre-commit.nix {jackpkgsInputs = inputs;};
      shell = import ./devshell.nix {jackpkgsInputs = inputs;};
      pulumi = import ./pulumi.nix {jackpkgsInputs = inputs;};
    };
  };
}
