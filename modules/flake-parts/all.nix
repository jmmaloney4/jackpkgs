{jackpkgsInputs}: {inputs, ...}: {
  imports = [
    (import ./devshell.nix {inherit jackpkgsInputs;})
    (import ./fmt.nix {inherit jackpkgsInputs;})
    (import ./just.nix {inherit jackpkgsInputs;})
    (import ./pre-commit.nix {inherit jackpkgsInputs;})
    (import ./pulumi.nix {inherit jackpkgsInputs;})
  ];
}
