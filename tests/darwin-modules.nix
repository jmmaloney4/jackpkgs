# Eval-only structure check for the common/ modules exported as `darwinModules`
# (ADR-051 Decision 5, amended).
#
# WHAT THIS DOES NOT VALIDATE. jackpkgs has no nix-darwin input, so this is
# NOT a nix-darwin evaluation. The modules are evaluated with `lib.evalModules`
# against stub declarations of the option PATHS they write (no freeform type),
# on an aarch64-darwin `pkgs`. The stubs are hand-written and loosely typed: a
# real nix-darwin option shaped differently (type, merge behaviour) would pass
# here and fail for a consumer. A real-nix-darwin eval was run by hand during
# PR #418 review (nix-darwin 4cff07d, aarch64-darwin: default and each of the
# ten named modules evaluate, assertions forced) but is not a check here.
#
# WHAT IT DOES CATCH. A common/ module that: fails to evaluate with a darwin
# platform; writes an option path absent from the stub set (undeclared paths
# fail with "option does not exist", e.g. an unguarded `systemd.*` or
# `boot.*`) -- the stub set lists only paths nix-darwin declares; declares a
# required option with a default; or is exported by name on one platform and
# not the other. It also pins that the platform guards take the darwin branch
# and the NixOS-only branches stay dark.
{
  inputs,
  lib,
  pkgs,
}: let
  darwinPkgs = inputs.nixpkgs.legacyPackages.aarch64-darwin;
  named = import ../modules/common/modules.nix;
  nixosNamed = import ../modules/nixos/modules.nix;

  # The option paths nix-darwin declares that common/ writes to. `systemd.*` is
  # deliberately absent (nix-darwin has none); `services.openssh.enable` is
  # present with no `.settings` (nix-darwin has neither `settings` nor systemd).
  stubs = {lib, ...}: let
    inherit (lib) mkOption types;
  in {
    options = {
      assertions = mkOption {
        type = types.listOf types.raw;
        default = [];
      };
      services.openssh.enable = mkOption {
        type = types.bool;
        default = false;
      };
      services.tailscale.enable = mkOption {
        type = types.bool;
        default = false;
      };
      services.tailscale.package = mkOption {
        type = types.package;
        default = darwinPkgs.tailscale;
      };
      environment.systemPackages = mkOption {
        type = types.listOf types.package;
        default = [];
      };
      # Declared (not freeform) so a common/ module writing any path outside
      # this list fails the check with "option does not exist". The types are
      # deliberately loose (`anything`/`lines`): they pin which PATHS exist,
      # not nix-darwin's value types.
      users.users = mkOption {
        type = types.attrsOf (types.submodule {freeformType = types.attrsOf types.anything;});
        default = {};
      };
      environment.etc = mkOption {
        type = types.attrsOf (types.submodule {freeformType = types.attrsOf types.anything;});
        default = {};
      };
      environment.variables = mkOption {
        type = types.attrsOf types.str;
        default = {};
      };
      environment.pathsToLink = mkOption {
        type = types.listOf types.str;
        default = [];
      };
      environment.shellInit = mkOption {
        type = types.lines;
        default = "";
      };
      nix.settings = mkOption {
        type = types.attrsOf types.anything;
        default = {};
      };
      fonts.packages = mkOption {
        type = types.listOf types.package;
        default = [];
      };
      programs.gnupg.agent = mkOption {
        type = types.attrsOf types.anything;
        default = {};
      };
      programs.ssh.knownHosts = mkOption {
        type = types.attrsOf types.anything;
        default = {};
      };
      programs.ssh.extraConfig = mkOption {
        type = types.lines;
        default = "";
      };
      programs.zsh.enable = mkOption {
        type = types.bool;
        default = false;
      };
      programs.zsh.enableBashCompletion = mkOption {
        type = types.bool;
        default = false;
      };
      programs.zsh.enableGlobalCompInit = mkOption {
        type = types.bool;
        default = true;
      };
    };
  };

  # Stand-in for the Determinate Nix darwin module's option.
  determinateStub = {lib, ...}: {
    options.determinateNix.customSettings = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = {};
    };
  };

  eval = modules:
    lib.evalModules {
      specialArgs.pkgs = darwinPkgs;
      modules = [stubs] ++ builtins.attrValues named ++ modules;
    };

  failed = e: map (a: a.message) (lib.filter (a: !a.assertion) e.config.assertions);

  wired = {
    jackpkgs = lib.genAttrs (builtins.attrNames named) (_: {enable = true;});
  };
  wiring = {
    jackpkgs.user.username = "alice";
    jackpkgs.nix.substituters.enable = true;
    jackpkgs.ssh = {
      authorizedKeys = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItest test"];
      authorizedKeysUsers = ["root" "alice"];
    };
    jackpkgs.attic = {
      endpoint = "https://attic.example.ts.net";
      pullCaches.c1 = "c1:KEY=";
    };
    jackpkgs.zsh.secretEnv.MY_TOKEN = "/run/agenix/my-token";
  };

  full = eval [determinateStub wired wiring];
  atticNoDeterminate = eval [wired wiring];
  c = full.config;

  inert = eval [determinateStub];
  mullvadOnDarwin = eval [
    determinateStub
    wired
    wiring
    {
      jackpkgs.tailscale.mullvad = {
        enable = true;
        exitNode = "x.mullvad.ts.net";
        exemptSourceCIDRs = ["10.0.0.0/8"];
      };
    }
  ];

  checks = [
    {
      msg = "every darwin-exported common module is also a nixosModule";
      ok = lib.all (n: nixosNamed ? ${n}) (builtins.attrNames named);
    }
    {
      msg = "fully-wired common set has no failed assertions";
      ok = failed full == [];
    }
    {
      msg = "importing without enabling is inert (no assertion, sshd off)";
      ok = failed inert == [] && c.services.openssh.enable && !inert.config.services.openssh.enable;
    }
    {
      msg = "ssh: key fan-out reaches root and alice; darwin sshd_config drop-in is written";
      ok =
        c.users.users.root.openssh.authorizedKeys.keys
        == wiring.jackpkgs.ssh.authorizedKeys
        && c.users.users.alice.openssh.authorizedKeys.keys == wiring.jackpkgs.ssh.authorizedKeys
        && c.environment.etc."ssh/sshd_config.d/100-nix-darwin.conf".text != "";
    }
    {
      msg = "attic: darwin writes determinateNix.customSettings, never nix.settings";
      ok =
        lib.any (s: lib.hasInfix "attic" s) c.determinateNix.customSettings.substituters
        && !(c.nix.settings ? substituters && lib.any (s: lib.hasInfix "attic" s) c.nix.settings.substituters);
    }
    {
      msg = "attic: enabling on darwin without determinateNix is refused, not silently dropped";
      ok = lib.any (m: lib.hasInfix "requires the Determinate Nix darwin module" m) (failed atticNoDeterminate);
    }
    {
      msg = "tailscale: no systemd units leak onto darwin";
      ok = !(c ? systemd);
    }
    {
      msg = "zsh: darwin disables enableGlobalCompInit";
      ok = c.programs.zsh.enableGlobalCompInit == false;
    }
    {
      msg = "tailscale.mullvad is refused on a platform without systemd";
      ok = lib.any (m: lib.hasInfix "requires systemd" m) (failed mullvadOnDarwin);
    }
  ];

  bad = map (x: x.msg) (lib.filter (x: !x.ok) checks);
in
  assert lib.assertMsg (bad == []) "darwin-modules-structure failed: ${builtins.toJSON bad}";
    pkgs.runCommand "darwin-modules-structure" {} ''
      echo 'jackpkgs common/ modules (${toString (builtins.attrNames named)}) evaluate against darwin option-path stubs;'
      echo 'NOT validated against real nix-darwin.'
      touch "$out"
    ''
