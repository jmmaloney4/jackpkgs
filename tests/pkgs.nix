# Tests for jackpkgs.pkgs option
# Verifies that consumer-provided overlayed nixpkgs propagate correctly to all module defaults
{
  lib,
  inputs,
}: let
  system = "x86_64-linux";
  flakeParts = inputs.flake-parts.lib;

  # Import the pkgs module
  pkgsModule = import ../modules/flake-parts/pkgs.nix {jackpkgsInputs = inputs;};

  # Import other modules that use jackpkgs.pkgs for their defaults
  fmtModule = import ../modules/flake-parts/fmt.nix {jackpkgsInputs = inputs;};
  quartoModule = import ../modules/flake-parts/quarto.nix {jackpkgsInputs = inputs;};
  justModule = import ../modules/flake-parts/just.nix {jackpkgsInputs = inputs;};
  pythonModule = import ../modules/flake-parts/python.nix {jackpkgsInputs = inputs;};
  shellModule = import ../modules/flake-parts/devshell.nix {jackpkgsInputs = inputs;};

  # Base module to disable strict checking
  baseModule = {
    _module.check = false;
  };

  # Evaluate a flake module configuration
  evalFlake = modules:
    flakeParts.evalFlakeModule {inherit inputs;} {
      systems = [system];
      imports = [baseModule] ++ modules;
    };

  # Get perSystem config for the test system
  getPerSystem = modules: (evalFlake modules).config.perSystem system;

  # Create a mock "overlayed" pkgs that we can identify
  # We add a marker attribute to verify it's being used
  mkMockPkgs = pkgs:
    pkgs
    // {
      _jackpkgsTestMarker = "overlayed";
      # Override some packages with marked versions
      quarto =
        pkgs.quarto
        // {
          _jackpkgsTestMarker = "overlayed-quarto";
        };
      treefmt =
        pkgs.treefmt
        // {
          _jackpkgsTestMarker = "overlayed-treefmt";
        };
      direnv =
        pkgs.direnv
        // {
          _jackpkgsTestMarker = "overlayed-direnv";
        };
      python312 =
        pkgs.python312
        // {
          _jackpkgsTestMarker = "overlayed-python312";
        };
    };
in {
  # ============================================================
  # Basic Option Tests
  # ============================================================

  # Test that jackpkgs.pkgs option exists
  testPkgsOptionExists = let
    perSystem = getPerSystem [pkgsModule];
  in {
    expr = perSystem ? jackpkgs && perSystem.jackpkgs ? pkgs;
    expected = true;
  };

  # Test that jackpkgs.pkgs defaults to pkgs (has standard nixpkgs attributes)
  testPkgsOptionDefaultsToStandardPkgs = let
    perSystem = getPerSystem [pkgsModule];
    pkgsValue = perSystem.jackpkgs.pkgs;
  in {
    expr =
      pkgsValue ? lib
      && pkgsValue ? stdenv
      && pkgsValue ? mkShell;
    expected = true;
  };

  # Test that jackpkgs.pkgs can be set to a custom value
  testPkgsOptionCanBeOverridden = let
    perSystem = getPerSystem [
      pkgsModule
      {
        perSystem = {pkgs, ...}: {
          jackpkgs.pkgs = mkMockPkgs pkgs;
        };
      }
    ];
  in {
    expr = perSystem.jackpkgs.pkgs._jackpkgsTestMarker or null;
    expected = "overlayed";
  };

  # ============================================================
  # Module Integration Tests - Verify defaults use jackpkgs.pkgs
  # ============================================================

  # Test that quarto module uses jackpkgs.pkgs for quartoPackage default
  testQuartoUsesJackpkgsPkgs = let
    perSystem = getPerSystem [
      pkgsModule
      shellModule
      quartoModule
      {
        perSystem = {pkgs, ...}: {
          jackpkgs.pkgs = mkMockPkgs pkgs;
        };
      }
    ];
  in {
    expr = perSystem.jackpkgs.quarto.quartoPackage._jackpkgsTestMarker or null;
    expected = "overlayed-quarto";
  };

  # Test that fmt module uses jackpkgs.pkgs for treefmtPackage default
  testFmtUsesJackpkgsPkgs = let
    perSystem = getPerSystem [
      pkgsModule
      fmtModule
      {
        perSystem = {pkgs, ...}: {
          jackpkgs.pkgs = mkMockPkgs pkgs;
        };
      }
    ];
  in {
    expr = perSystem.jackpkgs.fmt.treefmtPackage._jackpkgsTestMarker or null;
    expected = "overlayed-treefmt";
  };

  # Test that just module uses jackpkgs.pkgs for direnvPackage default
  testJustUsesJackpkgsPkgs = let
    perSystem = getPerSystem [
      pkgsModule
      justModule
      {
        perSystem = {pkgs, ...}: {
          jackpkgs.pkgs = mkMockPkgs pkgs;
        };
      }
    ];
  in {
    expr = perSystem.jackpkgs.just.direnvPackage._jackpkgsTestMarker or null;
    expected = "overlayed-direnv";
  };

  # Test that python module uses jackpkgs.pkgs for pythonPackage default
  testPythonUsesJackpkgsPkgs = let
    perSystem = getPerSystem [
      pkgsModule
      shellModule
      pythonModule
      {
        perSystem = {pkgs, ...}: {
          jackpkgs.pkgs = mkMockPkgs pkgs;
        };
      }
    ];
  in {
    expr = perSystem.jackpkgs.python.pythonPackage._jackpkgsTestMarker or null;
    expected = "overlayed-python312";
  };

  # ============================================================
  # Default Behavior Tests - When jackpkgs.pkgs is NOT set
  # ============================================================

  # Test that quarto uses standard pkgs when jackpkgs.pkgs is not set
  testQuartoDefaultsToStandardPkgs = let
    perSystem = getPerSystem [pkgsModule shellModule quartoModule];
    pkg = perSystem.jackpkgs.quarto.quartoPackage;
  in {
    # Should not have our test marker
    expr = pkg ? _jackpkgsTestMarker;
    expected = false;
  };

  # Test that fmt uses standard pkgs when jackpkgs.pkgs is not set
  testFmtDefaultsToStandardPkgs = let
    perSystem = getPerSystem [pkgsModule fmtModule];
    pkg = perSystem.jackpkgs.fmt.treefmtPackage;
  in {
    expr = pkg ? _jackpkgsTestMarker;
    expected = false;
  };

  # ============================================================
  # Explicit Override Tests - User can still override individual packages
  # ============================================================

  # Test that explicit package override takes precedence over jackpkgs.pkgs
  testExplicitOverrideTakesPrecedence = let
    customQuarto = {
      _jackpkgsTestMarker = "explicit-override";
      type = "derivation";
      name = "custom-quarto";
    };
    perSystem = getPerSystem [
      pkgsModule
      shellModule
      quartoModule
      {
        perSystem = {pkgs, ...}: {
          jackpkgs.pkgs = mkMockPkgs pkgs;
          jackpkgs.quarto.quartoPackage = customQuarto;
        };
      }
    ];
  in {
    expr = perSystem.jackpkgs.quarto.quartoPackage._jackpkgsTestMarker or null;
    expected = "explicit-override";
  };

  # ============================================================
  # Multiple Modules Tests - All modules respect same jackpkgs.pkgs
  # ============================================================

  # Test that all modules see the same jackpkgs.pkgs value
  testAllModulesShareSamePkgs = let
    perSystem = getPerSystem [
      pkgsModule
      shellModule
      fmtModule
      quartoModule
      justModule
      pythonModule
      {
        perSystem = {pkgs, ...}: {
          jackpkgs.pkgs = mkMockPkgs pkgs;
        };
      }
    ];
    markers = [
      (perSystem.jackpkgs.quarto.quartoPackage._jackpkgsTestMarker or null)
      (perSystem.jackpkgs.fmt.treefmtPackage._jackpkgsTestMarker or null)
      (perSystem.jackpkgs.just.direnvPackage._jackpkgsTestMarker or null)
      (perSystem.jackpkgs.python.pythonPackage._jackpkgsTestMarker or null)
    ];
  in {
    # All markers should be present (not null)
    expr = lib.all (m: m != null) markers;
    expected = true;
  };

}
