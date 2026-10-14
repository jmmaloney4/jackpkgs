# Eval-only structure check for the common/ modules exported as `darwinModules`
# (ADR-051 Decision 5, amended).
#
# WHAT THIS DOES NOT VALIDATE. jackpkgs has no nix-darwin input, so this is
# NOT a nix-darwin evaluation. The modules are evaluated with `lib.evalModules`
# against stub declarations of the option paths they define, on an
# aarch64-darwin `pkgs` (so `pkgs.stdenv.hostPlatform.isDarwin` is true).
# A real nix-darwin option that is shaped differently from its stub here (type,
# merge behaviour, a missing option) would pass this check and fail for a
# consumer. The first real consumer is the validation.
#
# WHAT IT DOES CATCH. A common/ module that: fails to evaluate with a darwin
# platform; references an option path the stub set (a faithful list of what
# nix-darwin declares) lacks, so a NixOS-only path leaks in (e.g. an unguarded
# `systemd.*`); declares a required option with a default; or is exported by
# name on one platform and not the other. It also pins that the platform guards
# take the darwin branch and the NixOS-only branches stay dark.
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
    freeformType = types.lazyAttrsOf types.anything;
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
    };
  };

  eval = modules:
    lib.evalModules {
      specialArgs.pkgs = darwinPkgs;
      modules = [stubs {nixpkgs = null;}] ++ builtins.attrValues named ++ modules;
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

  full = eval [wired wiring];
  c = full.config;

  inert = eval [];
  mullvadOnDarwin = eval [wired wiring {jackpkgs.tailscale.mullvad = {enable = true; exitNode = "x.mullvad.ts.net"; exemptSourceCIDRs = ["10.0.0.0/8"];};}];

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
        c.users.users.root.openssh.authorizedKeys.keys == wiring.jackpkgs.ssh.authorizedKeys
        && c.users.users.alice.openssh.authorizedKeys.keys == wiring.jackpkgs.ssh.authorizedKeys
        && c.environment.etc."ssh/sshd_config.d/100-nix-darwin.conf".text != "";
    }
    {
      msg = "attic: darwin branch does not write nix.settings (no determinateNix option declared)";
      ok = !(c ? nix) || !(c.nix.settings ? substituters) || !(lib.any (s: lib.hasInfix "attic" s) c.nix.settings.substituters);
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
      echo 'jackpkgs common/ modules (${toString (builtins.attrNames named)}) evaluate against darwin stubs;'
      echo 'NOT validated against real nix-darwin.'
      touch "$out"
    ''
