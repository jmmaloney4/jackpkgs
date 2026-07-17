# jackpkgs.lsp — standard lightweight LSP servers in the devshell
#
# Installs LSP binaries into the devshell based on which jackpkgs language
# modules are enabled. Editors and agent harnesses discover the binaries
# on PATH.
#
# See ADR 043 for design rationale.
{jackpkgsInputs}: {
  inputs,
  config,
  lib,
  ...
}: let
  inherit (lib) mkIf;
  cfg = config.jackpkgs.lsp;
  nodejsEnabled = config.jackpkgs.nodejs.enable or false;
  pulumiEnabled = config.jackpkgs.pulumi.enable or false;
  pythonEnabled = config.jackpkgs.python.enable or false;
in {
  options = let
    inherit (lib) types mkOption mkEnableOption;
    inherit (jackpkgsInputs.flake-parts.lib) mkDeferredModuleOption;
  in {
    jackpkgs.lsp = {
      enable = mkEnableOption "jackpkgs-lsp (standard lightweight LSP servers)" // {default = false;};

      typescript.backend = mkOption {
        type = types.enum ["tsgo" "typescript-language-server" "none"];
        default = "typescript-language-server";
        description = ''
          TypeScript/JavaScript LSP backend.

          `tsgo` is the native Go compiler from TypeScript 7 — far lighter
          than tsserver. It comes from the nixpkgs `typescript-go` package
          and serves LSP via `tsgo --lsp --stdio`.

          Note that `typescript-go` also provides `tsc` as a symlink to the
          same binary, so selecting `"tsgo"` puts the TypeScript 7 compiler
          on PATH in place of nixpkgs `typescript`. Repos pinned to
          TypeScript 6 should keep that in mind when invoking bare `tsc`
          from the devshell.

          Defaults to `"typescript-language-server"` (the current
          tsserver-based LSP) for broad compatibility.
        '';
      };

      python.backend = mkOption {
        type = types.enum ["ty" "pyright" "none"];
        default = "ty";
        description = ''
          Python semantic LSP backend.

          `ty` is Astral's Rust-based type checker — 10-100× faster than
          pyright. Defaults to `"ty"`.
        '';
      };

      python.lintBackend = mkOption {
        type = types.enum ["ruff" "none"];
        default = "ruff";
        description = ''
          Python lint/format LSP backend.
          Defaults to `"ruff"` (ruff server).
        '';
      };

      nix.backend = mkOption {
        type = types.enum ["nil" "nixd" "none"];
        default = "nil";
        description = "Nix LSP backend. Defaults to `nil`.";
      };

      rust.enable = mkEnableOption "rust-analyzer" // {default = false;};
    };

    perSystem = mkDeferredModuleOption ({
      config,
      lib,
      pkgs,
      ...
    }: {
      options.jackpkgs.lsp = {
        extraPackages = mkOption {
          type = types.listOf types.package;
          default = [];
          description = ''
            Additional LSP packages to include in the devshell beyond what
            auto-selection provides.
          '';
        };
      };
    });
  };

  config = mkIf cfg.enable {
    perSystem = {
      pkgs,
      lib,
      config,
      ...
    }: let
      sysCfg = config.jackpkgs.lsp;
      jpkgs = config.jackpkgs.pkgs;

      tsWanted = cfg.typescript.backend != "none" && (nodejsEnabled || pulumiEnabled);
      tsPackages =
        if cfg.typescript.backend == "tsgo"
        then [jpkgs.typescript-go]
        else [jpkgs.typescript-language-server jpkgs.typescript];

      pyWanted = cfg.python.backend != "none" && pythonEnabled;
      pyPackages =
        if cfg.python.backend == "ty"
        then [jpkgs.ty]
        else [jpkgs.pyright];

      pyLintPackages =
        if cfg.python.lintBackend == "ruff"
        then [jpkgs.ruff]
        else [];

      nixPackages =
        if cfg.nix.backend == "nil"
        then [jpkgs.nil]
        else [jpkgs.nixd];

      rustPackages = lib.optional cfg.rust.enable jpkgs.rust-analyzer;

      lspPackages =
        (lib.optionals tsWanted tsPackages)
        ++ (lib.optionals pyWanted pyPackages)
        ++ (lib.optionals pyWanted pyLintPackages)
        ++ nixPackages
        ++ [jpkgs.yaml-language-server jpkgs.bash-language-server]
        ++ rustPackages
        ++ sysCfg.extraPackages;
    in {
      jackpkgs.shell.packages = lspPackages;
    };
  };
}
