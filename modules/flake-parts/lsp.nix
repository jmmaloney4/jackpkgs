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
          than tsserver. As of nixpkgs 2026-09-08, it ships as the nixpkgs
          `typescript` package itself (folded in from the formerly-separate
          `typescript-go` package) and serves LSP via `tsc --lsp`.

          Note that nixpkgs `typescript` is therefore now the TypeScript 7
          (Go) compiler regardless of backend choice — the
          `"typescript-language-server"` backend below also puts this `tsc`
          on PATH. Repos pinned to TypeScript 6 should keep that in mind
          when invoking bare `tsc` from the devshell.

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
        then
          # Fail loudly and actionably if the consumer's nixpkgs lacks a
          # working `typescript` package, rather than a bare eval error —
          # and never silently drop the LSP, which is the bug this backend
          # previously had. Need BOTH `?` and tryEval, for two distinct
          # failure modes neither catches alone:
          #   - `?` (hasAttr) alone missed the actual 2026-09-08 regression:
          #     nixpkgs deprecates/renames packages by aliasing the attribute
          #     to a `throw`, and hasAttr only checks that the key exists,
          #     not that the value forces without throwing — so
          #     `jpkgs ? typescript-go` kept returning true while forcing
          #     `jpkgs.typescript-go` threw.
          #   - tryEval alone can't replace `?`: a genuinely absent attribute
          #     raises via Nix's `.` ("attribute missing") path, which
          #     tryEval does NOT catch (only throw/abort/assert) — confirmed
          #     directly: `builtins.tryEval {}.x` re-raises uncaught rather
          #     than returning `{success = false;}`.
          # `?` short-circuits the missing case before `.` is ever forced, so
          # tryEval only has to handle the "present but throws" case.
          let
            attempt = jpkgs ? typescript && (builtins.tryEval jpkgs.typescript).success;
          in
            if attempt
            then [jpkgs.typescript]
            else
              throw ''
                jackpkgs.lsp: typescript.backend = "tsgo" requires a nixpkgs
                that provides a working `typescript` package (the Go-rewritten
                compiler, folded into `typescript` as of nixpkgs 2026-09-08;
                formerly published as the separate `typescript-go` package).
                The nixpkgs behind `jackpkgs.pkgs` does not have one. Advance
                that nixpkgs pin, or set
                typescript.backend = "typescript-language-server".
              ''
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
