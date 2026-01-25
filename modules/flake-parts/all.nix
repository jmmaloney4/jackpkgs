{jackpkgsInputs}: {inputs, ...}: {
  imports = [
    (import ./pkgs.nix {inherit jackpkgsInputs;})
    (import ./project-root.nix {inherit jackpkgsInputs;})
    (import ./python.nix {inherit jackpkgsInputs;})
    (import ./devshell.nix {inherit jackpkgsInputs;})
    (import ./fmt.nix {inherit jackpkgsInputs;})
    (import ./just.nix {inherit jackpkgsInputs;})
    (import ./pre-commit.nix {inherit jackpkgsInputs;})
    (import ./nodejs.nix {inherit jackpkgsInputs;})
    (import ./pnpm.nix {inherit jackpkgsInputs;})
    (import ./pulumi.nix {inherit jackpkgsInputs;})
    (import ./quarto.nix {inherit jackpkgsInputs;})
    (import ./checks.nix {inherit jackpkgsInputs;})
  ];
}
