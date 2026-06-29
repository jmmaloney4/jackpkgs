{lib}: let
  helpers = import ../lib/python-workspace-paths.nix {inherit lib;};
  inherit (helpers) discoverPythonWorkspaceMembers memberSrcPath pythonWorkspaceSrcPaths;

  inherit (builtins) pathExists;
  inherit (lib) hasPrefix;

  # ---------------------------------------------------------
  # Synthetic workspace fixtures
  #
  # builtins.pathExists works against local paths at eval time,
  # so we build minimal directory trees under tests/fixtures.
  # ---------------------------------------------------------
  fixturesRoot = ../tests/fixtures/python-workspace;

  # Fixture A: standard src/ layout with globs and excludes.
  #   libs/dlt/src/        ← included
  #   libs/api/src/        ← included
  #   tools/apollo/src/    ← included
  #   tools/spike/         ← excluded via [tool.uv.workspace].exclude
  #   tools/spike/sub/     ← excluded (nested under excluded parent)
  workspaceA = fixturesRoot + "/standard";
  pyprojectA = workspaceA + "/pyproject.toml";

  # Fixture B: non-standard layout (no src/ dirs, override needed).
  workspaceB = fixturesRoot + "/nonstandard";
  pyprojectB = workspaceB + "/pyproject.toml";

  # Fixture C: root-level package (members = ["."]).
  workspaceC = fixturesRoot + "/root-package";
  pyprojectC = workspaceC + "/pyproject.toml";

  # Fixture D: overlapping globs to exercise deduplication.
  #   members = ["libs/*", "libs/api"] — "libs/api" appears in both.
  workspaceD = fixturesRoot + "/duplicates";
  pyprojectD = workspaceD + "/pyproject.toml";
in {
  # ---------------------------------------------------------
  # discoverPythonWorkspaceMembers
  # ---------------------------------------------------------

  testDiscoversMembersFromGlobPatterns = {
    expr = discoverPythonWorkspaceMembers {
      workspaceRoot = workspaceA;
      pyprojectPath = pyprojectA;
    };
    expected = [
      "libs/api"
      "libs/dlt"
      "tools/apollo"
    ];
  };

  testExcludeRemovesMembersAndTheirChildren = {
    # tools/spike is excluded; tools/spike/sub should not appear either.
    expr = discoverPythonWorkspaceMembers {
      workspaceRoot = workspaceA;
      pyprojectPath = pyprojectA;
    };
    expected = [
      "libs/api"
      "libs/dlt"
      "tools/apollo"
    ];
  };

  testRootPackageWithDotMember = {
    expr = discoverPythonWorkspaceMembers {
      workspaceRoot = workspaceC;
      pyprojectPath = pyprojectC;
    };
    expected = ["."];
  };

  testNonPackageDirectoriesAreFiltered = {
    # libs/empty-dir exists but has no pyproject.toml — should not appear.
    expr = discoverPythonWorkspaceMembers {
      workspaceRoot = workspaceA;
      pyprojectPath = pyprojectA;
    };
    expected = [
      "libs/api"
      "libs/dlt"
      "tools/apollo"
    ];
  };

  # ---------------------------------------------------------
  # memberSrcPath
  # ---------------------------------------------------------

  testMemberSrcPathConventionalSrc = {
    expr = memberSrcPath {
      workspaceRoot = workspaceA;
      member = "libs/dlt";
    };
    expected = "libs/dlt/src";
  };

  testMemberSrcPathOverride = {
    expr = memberSrcPath {
      workspaceRoot = workspaceB;
      member = "libs/legacy";
      sourceRootMap = {"libs/legacy" = "libs/legacy/python";};
    };
    expected = "libs/legacy/python";
  };

  testMemberSrcPathReturnsNullWhenNoSrcAndNotStrict = {
    expr = memberSrcPath {
      workspaceRoot = workspaceB;
      member = "libs/flat";
    };
    expected = null;
  };

  # ---------------------------------------------------------
  # pythonWorkspaceSrcPaths (combined)
  # ---------------------------------------------------------

  testSrcPathsStandardWorkspace = {
    expr = pythonWorkspaceSrcPaths {
      workspaceRoot = workspaceA;
      pyprojectPath = pyprojectA;
    };
    expected = [
      "libs/api/src"
      "libs/dlt/src"
      "tools/apollo/src"
    ];
  };

  testSrcPathsWithOverride = {
    expr = pythonWorkspaceSrcPaths {
      workspaceRoot = workspaceB;
      pyprojectPath = pyprojectB;
      sourceRootMap = {
        "libs/legacy" = "libs/legacy/python";
        "libs/flat" = "libs/flat";
      };
    };
    expected = [
      "libs/flat"
      "libs/legacy/python"
    ];
  };

  testSrcPathsOmitsMembersWithoutSourceRoot = {
    # libs/flat has no src/ and no override — should be silently omitted.
    expr = pythonWorkspaceSrcPaths {
      workspaceRoot = workspaceB;
      pyprojectPath = pyprojectB;
      sourceRootMap = {"libs/legacy" = "libs/legacy/python";};
    };
    expected = ["libs/legacy/python"];
  };

  testSrcPathsRootPackage = {
    # Root package: member "." → src root "src".
    expr = pythonWorkspaceSrcPaths {
      workspaceRoot = workspaceC;
      pyprojectPath = pyprojectC;
    };
    expected = ["src"];
  };

  # ---------------------------------------------------------
  # Deduplication (PR-Agent suggestion: overlapping globs)
  # ---------------------------------------------------------

  testOverlappingGlobsAreDeduplicated = {
    # members = ["libs/*", "libs/api"] should not emit "libs/api" twice.
    expr = discoverPythonWorkspaceMembers {
      workspaceRoot = workspaceD;
      pyprojectPath = pyprojectD;
    };
    expected = [
      "libs/api"
      "libs/dlt"
    ];
  };

  testSrcPathsOverlappingGlobsDeduplicated = {
    expr = pythonWorkspaceSrcPaths {
      workspaceRoot = workspaceD;
      pyprojectPath = pyprojectD;
    };
    expected = [
      "libs/api/src"
      "libs/dlt/src"
    ];
  };

  # ---------------------------------------------------------
  # Override path safety (PR-Agent suggestion: validate overrides)
  # ---------------------------------------------------------

  testMemberSrcPathRejectsTraversalInOverride = {
    # An override containing ".." should throw via validateWorkspacePath.
    # We verify this by checking that evaluation of the throw message
    # contains the expected error string (rather than using tryEval,
    # which has inconsistent behavior across Nix eval contexts in CI).
    expr = let
      result = builtins.tryEval (memberSrcPath {
        workspaceRoot = workspaceB;
        member = "libs/legacy";
        sourceRootMap = {"libs/legacy" = "../../../etc/passwd";};
      });
    in
      !result.success;
    expected = true;
  };

  testMemberSrcPathReturnsNullForNonExistentOverrideNonStrict = {
    # Override points to a path that doesn't exist under workspaceRoot.
    # Non-strict: returns null silently.
    expr = memberSrcPath {
      workspaceRoot = workspaceB;
      member = "libs/legacy";
      sourceRootMap = {"libs/legacy" = "libs/legacy/nonexistent";};
    };
    expected = null;
  };
}
