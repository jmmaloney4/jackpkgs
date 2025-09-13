{jackpkgsInputs}: {inputs, ...}: {
  imports = [
    (import ./fmt.nix {inherit jackpkgsInputs;})
    (import ./just.nix {inherit jackpkgsInputs;})
    (import ./pre-commit.nix {inherit jackpkgsInputs;})
  ];
}
