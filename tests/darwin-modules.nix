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
  nixosNamed = import ../modules/nixos/modules.nix inputs;

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
      networking.hostName = mkOption {
        type = types.nullOr types.str;
        default = null;
      };
      # The nix-darwin Home Manager module's surface the account modules write
      # to. `users.<n>` is a freeform submodule: `imports` (the jackpkgs HM
      # aggregator plus consumer modules) are accepted but the Home Manager
      # module system is NOT run -- this stub proves the darwin side wires the
      # right option paths, not that the Home Manager config evaluates (that is
      # tests/home-modules-instantiate.nix).
      home-manager.useGlobalPkgs = mkOption {
        type = types.bool;
        default = false;
      };
      home-manager.useUserPackages = mkOption {
        type = types.bool;
        default = false;
      };
      home-manager.extraSpecialArgs = mkOption {
        type = types.attrs;
        default = {};
      };
      home-manager.users = mkOption {
        type = types.attrsOf (types.submoduleWith {
          modules = [{freeformType = types.attrsOf types.anything;}];
        });
        default = {};
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
    jackpkgs.operator.home.modules = [{home.stateVersion = "26.05";}];
    jackpkgs.build-user.username = "builder";
    jackpkgs.guest-user = {
      username = "carol";
      uid = 1002;
      authorizedKeys = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIcarol carol"];
    };
    networking.hostName = "mac";
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
      msg = "operator: darwin uid/shell, no linux-only attributes, HM user wired with hostname";
      ok =
        c.users.users.alice.uid
        == 501
        && !(c.users.users.alice ? isNormalUser)
        && !(c.users.users.alice ? extraGroups)
        && c.home-manager.users ? alice
        && c.home-manager.extraSpecialArgs.hostname == "mac";
    }
    {
      msg = "operator: darwin home directory is set (HM derives home.homeDirectory from it)";
      ok = c.users.users.alice.home == "/Users/alice";
    }
    {
      msg = "build-user and guest-user: darwin accounts, guest has no HM user";
      ok =
        !(c.users.users.builder ? isNormalUser)
        && c.home-manager.users ? builder
        && c.users.users.carol.uid == 1002
        && !(c.home-manager.users ? carol);
    }
    {
      msg = "guest-user: a macOS-range uid (501) is accepted on darwin, no Linux uid assertion fires";
      ok = let
        e = eval [
          determinateStub
          wired
          wiring
          {jackpkgs.guest-user.uid = lib.mkForce 501;}
        ];
      in
        e.config.users.users.carol.uid == 501 && failed e == [];
    }
    {
      msg = "operator: an unset (null) networking.hostName is refused, not passed on as a null specialArg";
      ok = let
        e = eval [
          determinateStub
          wired
          wiring
          {networking.hostName = lib.mkForce null;}
        ];
      in
        lib.any (m: lib.hasInfix "requires networking.hostName" m) (failed e);
    }
    {
      msg = "profile: the platform-agnostic baseline is exported (no HM module import, no locale)";
      ok = named ? profile && !(c ? i18n);
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
