# Tests for jackpkgs.lsp option wiring
{
  lib,
  inputs,
}: let
  system = "x86_64-linux";
  flakeParts = inputs.flake-parts.lib;

  pkgsModule = import ../modules/flake-parts/pkgs.nix {jackpkgsInputs = inputs;};
  shellModule = import ../modules/flake-parts/devshell.nix {jackpkgsInputs = inputs;};
  pythonModule = import ../modules/flake-parts/python.nix {jackpkgsInputs = inputs;};
  nodejsModule = import ../modules/flake-parts/nodejs.nix {jackpkgsInputs = inputs;};
  pulumiModule = import ../modules/flake-parts/pulumi.nix {jackpkgsInputs = inputs;};
  lspModule = import ../modules/flake-parts/lsp.nix {jackpkgsInputs = inputs;};

  evalFlake = modules:
    flakeParts.evalFlakeModule {inherit inputs;} {
      systems = [system];
      imports = modules;
    };

  getPerSystem = modules: (evalFlake modules).config.perSystem system;

  mkNodeConfig = {
    _module.check = false;
    jackpkgs.nodejs = {
      enable = true;
      pnpmDepsHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
      projectRoot = ../.;
    };
  };

  mkPulumiConfig = {
    _module.check = false;
    jackpkgs.pulumi = {
      enable = true;
      backendUrl = "file:///tmp/pulumi-state";
      secretsProvider = "passphrase";
      defaultStack = "dev";
      stacks = [];
    };
  };

  mkPythonConfig = {
    _module.check = false;
    jackpkgs.python = {
      enable = true;
      workspaceRoot = ../.;
    };
  };

  hasPackageNamed = name: packages:
    lib.any (pkg: (pkg.pname or null) == name || (pkg.name or "") == name || lib.hasPrefix (name + "-") (pkg.name or "")) packages;
in {
  testLspModuleRegistersOption = let
    perSystem = getPerSystem [pkgsModule shellModule lspModule];
  in {
    expr = perSystem ? jackpkgs && perSystem.jackpkgs ? lsp;
    expected = true;
  };

  testLspAddsAlwaysOnServers = let
    perSystem = getPerSystem [
      pkgsModule
      shellModule
      lspModule
      {
        _module.check = false;
        jackpkgs.lsp.enable = true;
      }
    ];
    packages = perSystem.jackpkgs.shell.packages;
  in {
    expr =
      hasPackageNamed "nil" packages
      && hasPackageNamed "yaml-language-server" packages
      && hasPackageNamed "bash-language-server" packages;
    expected = true;
  };

  testLspAddsPythonServersWhenPythonEnabled = let
    perSystem = getPerSystem [
      pkgsModule
      shellModule
      pythonModule
      lspModule
      mkPythonConfig
      {
        _module.check = false;
        jackpkgs.lsp.enable = true;
      }
    ];
    packages = perSystem.jackpkgs.shell.packages;
  in {
    expr = hasPackageNamed "ty" packages && hasPackageNamed "ruff" packages;
    expected = true;
  };

  testLspAddsTypescriptFallbackWhenNodejsEnabled = let
    perSystem = getPerSystem [
      pkgsModule
      shellModule
      nodejsModule
      lspModule
      mkNodeConfig
      {
        _module.check = false;
        jackpkgs.lsp.enable = true;
      }
    ];
    packages = perSystem.jackpkgs.shell.packages;
  in {
    expr = hasPackageNamed "typescript-language-server" packages && hasPackageNamed "typescript" packages;
    expected = true;
  };

  testLspAddsTypescriptFallbackWhenPulumiEnabled = let
    perSystem = getPerSystem [
      pkgsModule
      shellModule
      pulumiModule
      lspModule
      mkPulumiConfig
      {
        _module.check = false;
        jackpkgs.lsp.enable = true;
      }
    ];
    packages = perSystem.jackpkgs.shell.packages;
  in {
    expr = hasPackageNamed "typescript-language-server" packages && hasPackageNamed "typescript" packages;
    expected = true;
  };

  # Regression: `backend = "tsgo"` must resolve to the nixpkgs `typescript-go`
  # package. This previously guarded on a `tsgo` attr that nixpkgs never
  # defines, so the backend silently produced no TypeScript LSP at all.
  testLspAddsTsgoWhenBackendIsTsgo = let
    perSystem = getPerSystem [
      pkgsModule
      shellModule
      nodejsModule
      lspModule
      mkNodeConfig
      {
        _module.check = false;
        jackpkgs.lsp.enable = true;
        jackpkgs.lsp.typescript.backend = "tsgo";
      }
    ];
    packages = perSystem.jackpkgs.shell.packages;
  in {
    expr = hasPackageNamed "typescript-go" packages;
    expected = true;
  };

  # The tsgo backend replaces the tsserver stack rather than supplementing it.
  testLspTsgoBackendExcludesTypescriptLanguageServer = let
    perSystem = getPerSystem [
      pkgsModule
      shellModule
      nodejsModule
      lspModule
      mkNodeConfig
      {
        _module.check = false;
        jackpkgs.lsp.enable = true;
        jackpkgs.lsp.typescript.backend = "tsgo";
      }
    ];
    packages = perSystem.jackpkgs.shell.packages;
  in {
    expr = !(hasPackageNamed "typescript-language-server" packages);
    expected = true;
  };

  # When the tsgo backend is selected but the consumer's nixpkgs lacks
  # `typescript-go`, eval must fail loudly rather than silently drop the LSP.
  # Silent-empty was the original bug; this guarantees we never regress to it,
  # even in the missing-attr case.
  testLspTsgoBackendThrowsWhenTypescriptGoAbsent = let
    perSystem = getPerSystem [
      pkgsModule
      shellModule
      nodejsModule
      lspModule
      mkNodeConfig
      {
        _module.check = false;
        jackpkgs.lsp.enable = true;
        jackpkgs.lsp.typescript.backend = "tsgo";
        # jackpkgs.pkgs is a perSystem option, so it must be overridden inside
        # perSystem — a top-level set would be silently dropped by check=false.
        perSystem = {
          system,
          lib,
          ...
        }: {
          jackpkgs.pkgs =
            lib.mkForce (removeAttrs inputs.nixpkgs.legacyPackages.${system} ["typescript-go"]);
        };
      }
    ];
    # deepSeq the package names (not builtins.length): length forces only the
    # list spine, so it catches a throw at the list-value level (today's case)
    # but would silently miss a throw that ever moved to an element. Forcing
    # each pname is robust to that refactor without building the derivations.
    eval = builtins.tryEval (
      builtins.deepSeq
      (map (p: p.pname or p.name or "") perSystem.jackpkgs.shell.packages)
      true
    );
  in {
    expr = eval.success;
    expected = false;
  };

  testLspDoesNotAddTypescriptByDefaultWithoutNodeOrPulumi = let
    perSystem = getPerSystem [
      pkgsModule
      shellModule
      lspModule
      {
        _module.check = false;
        jackpkgs.lsp.enable = true;
      }
    ];
    packages = perSystem.jackpkgs.shell.packages;
  in {
    expr = !(hasPackageNamed "typescript-language-server" packages);
    expected = true;
  };

  testLspAddsRustAnalyzerWhenEnabled = let
    perSystem = getPerSystem [
      pkgsModule
      shellModule
      lspModule
      {
        _module.check = false;
        jackpkgs.lsp.enable = true;
        jackpkgs.lsp.rust.enable = true;
      }
    ];
    packages = perSystem.jackpkgs.shell.packages;
  in {
    expr = hasPackageNamed "rust-analyzer" packages;
    expected = true;
  };
}
