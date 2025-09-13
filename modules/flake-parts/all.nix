{inputs, ...}: {
  imports = [
    (import ./fmt.nix {jackpkgsInputs = inputs;})
    (import ./just.nix {jackpkgsInputs = inputs;})
    (import ./pre-commit.nix {jackpkgsInputs = inputs;})
  ];
}
