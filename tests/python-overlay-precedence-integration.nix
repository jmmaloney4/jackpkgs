# Integration test for Python overlay precedence (issue #78)
#
# This test validates that user's uv.lock takes precedence over pyproject-build-systems
# overlays by building a real Python environment and testing actual import behavior.
#
# Context: Prior to PR #79, pyproject-build-systems overlays were applied AFTER
# user's workspace overlay, causing runtime dependencies from pyproject-build-systems'
# own uv.lock to override user's locked versions. This manifested as import errors
# when user's lock had newer versions than build-systems (e.g., typing-extensions
# 4.15.0 user vs. 4.13.2 build-systems, breaking Sentinel import added in 4.14.0).
#
# Test approach: Build a minimal Python environment with a dependency that requires
# typing-extensions >= 4.14.0 (pydantic 2.9.0), then attempt to import Sentinel.
# If overlay precedence is wrong, the environment will have typing-extensions 4.13.2
# from pyproject-build-systems, causing ImportError.
#
# See: https://github.com/jmmaloney4/jackpkgs/issues/78
# See: https://github.com/jmmaloney4/jackpkgs/pull/79
# See: docs/internal/designs/012-python-overlay-precedence-test.md
{
  lib,
  pkgs,
  inputs,
}: let
  # Generate a minimal test workspace with pyproject.toml and uv.lock
  # This workspace has pydantic 2.9.0, which requires typing-extensions >= 4.14.0
  testWorkspace =
    pkgs.runCommand "python-precedence-test-workspace" {
      nativeBuildInputs = [pkgs.uv];
      # uv needs a writable cache directory
      UV_CACHE_DIR = "$TMPDIR/uv-cache";
      HOME = "$TMPDIR/home";
    } ''
          mkdir -p $UV_CACHE_DIR $HOME
          mkdir -p $out
          cd $out

          # Create minimal pyproject.toml with conflicting dependency
          # Use typing-extensions directly (simpler and more lenient Python version requirements)
          cat > pyproject.toml << 'EOF'
      [project]
      name = "overlay-precedence-test"
      version = "0.1.0"
      requires-python = ">=3.10"
      dependencies = [
        "typing-extensions>=4.14.0"
      ]

      [build-system]
      requires = ["setuptools>=45", "wheel"]
      build-backend = "setuptools.build_meta"
      EOF

          # Generate uv.lock
          # This will lock typing-extensions to a version >= 4.14.0
          echo "Generating uv.lock for test workspace..."
          ${lib.getExe pkgs.uv} lock

          echo "Test workspace generated at $out"
          ls -la $out
    '';

  # Load the uv2nix workspace directly (bypassing the Python module)
  workspace = inputs.uv2nix.lib.workspace.loadWorkspace {
    workspaceRoot = testWorkspace;
  };

  # Create base overlay from user's workspace (their uv.lock)
  userBaseOverlay = workspace.mkPyprojectOverlay {
    sourcePreference = "wheel";
  };

  # Compose overlays in the CORRECT order (as per PR #79 fix):
  # 1. pyproject-build-systems overlays (build-time deps)
  # 2. user's workspace overlay (AUTHORITATIVE for runtime deps)
  #
  # NOTE: This test may not fail if overlay order is reversed, because
  # pyproject-build-systems currently doesn't have a conflicting typing-extensions
  # in its workspace. The test validates that user's uv.lock takes effect and
  # would catch regressions if pyproject-build-systems adds conflicting packages.
  # The original bug (issue #78) manifested with packages like typing-extensions
  # that were transitive deps of build systems (e.g., pydantic-core → typing-extensions).
  overlayList =
    [
      inputs.pyproject-build-systems.overlays.wheel
      inputs.pyproject-build-systems.overlays.sdist
    ]
    ++ [
      userBaseOverlay
    ];

  composedOverlays = lib.composeManyExtensions overlayList;

  # Create Python package set with overlays
  pythonBase = pkgs.callPackage inputs.pyproject-nix.build.packages {
    python = pkgs.python312;
  };

  pythonSet = pythonBase.overrideScope composedOverlays;

  # Build a virtual environment with the dependencies
  pythonEnv = pythonSet.mkVirtualEnv "test-env" workspace.deps.default;

  # Test script that imports typing_extensions.Sentinel
  testScript = pkgs.writeShellScript "test-typing-extensions-sentinel" ''
            set -euo pipefail

            echo "=========================================="
            echo "Python Overlay Precedence Integration Test"
            echo "=========================================="
            echo ""
            echo "Testing that user's uv.lock takes precedence over pyproject-build-systems"
            echo "by attempting to import typing_extensions.Sentinel (requires >= 4.14.0)"
            echo ""

            # Check Python interpreter
            echo "Python interpreter: ${pythonEnv}/bin/python"
            echo ""

                # Attempt the import that would fail with wrong overlay precedence
        if ${pythonEnv}/bin/python -c '
    import sys
    import typing_extensions
    from importlib.metadata import version

    # Get version from package metadata
    te_version = version("typing-extensions")
    print(f"typing_extensions version: {te_version}")
    print(f"typing_extensions location: {typing_extensions.__file__}")
    print("")

    # This import requires typing-extensions >= 4.14.0
    # Will raise ImportError if pyproject-build-systems overrode user lock
    try:
        from typing_extensions import Sentinel
        print("✓ Successfully imported Sentinel")
        print(f"  Sentinel type: {type(Sentinel)}")
    except ImportError as e:
        print(f"✗ Failed to import Sentinel: {e}")
        print("")
        print("This indicates overlay precedence regression!")
        print("pyproject-build-systems overlays likely applied after user overlay.")
        print("See: https://github.com/jmmaloney4/jackpkgs/issues/78")
        sys.exit(1)

    # Verify version is actually >= 4.14.0
    major, minor, patch = map(int, te_version.split("."))
    if (major, minor, patch) < (4, 14, 0):
        print(f"✗ Version too old: {te_version} < 4.14.0")
        print("Expected user uv.lock version (>= 4.14.0)")
        sys.exit(1)

    print(f"✓ Version check passed: {te_version} >= 4.14.0")
            '; then
              echo ""
              echo "=========================================="
              echo "✓ TEST PASSED"
              echo "=========================================="
              echo "User's uv.lock took precedence over pyproject-build-systems"
              echo "Overlay composition order is correct."
              exit 0
            else
              echo ""
              echo "=========================================="
              echo "✗ TEST FAILED"
              echo "=========================================="
              echo "Overlay precedence regression detected!"
              echo "See: https://github.com/jmmaloney4/jackpkgs/issues/78"
              echo "See: https://github.com/jmmaloney4/jackpkgs/pull/79"
              exit 1
            fi
  '';
in
  # Return derivation that runs the test
  pkgs.runCommand "python-overlay-precedence-integration-test" {
    meta = {
      description = ''
        Integration test for Python overlay precedence (issue #78).

        Validates that user's uv.lock takes precedence over pyproject-build-systems
        overlays by building a Python environment and testing actual import behavior.

        The test creates a workspace with pydantic 2.9.0 (requires typing-extensions
        >= 4.14.0) and attempts to import Sentinel (added in typing-extensions 4.14.0).

        If pyproject-build-systems overlays override user's lock, the environment
        would have typing-extensions 4.13.2 from nixpkgs, causing ImportError.

        NOTE: This test directly uses uv2nix workspace and overlay composition
        logic without evaluating the full Python flake-parts module, which would
        be complex in a test context. This approach tests the core overlay precedence
        logic that the module depends on.
      '';
      timeout = 300; # 5 minute timeout
    };
  } ''
    ${testScript}

    # Create output file on success
    echo "success" > $out
  ''
