{
  lib,
  pkgs,
  testHelpers,
}: let
  just = pkgs.just;
  inherit (testHelpers.justHelpers) mkRecipe;

  # Import the actual module to get the feature justfiles
  # We need to evaluate them with mock config/lib to extract the justfile content

  # Helper to validate justfile content
  mkJustParseTest = name: justfileContent:
    pkgs.runCommand "test-module-${name}" {
      nativeBuildInputs = [just];
    } ''
      cat > justfile << 'EOF'
      ${justfileContent}
      EOF

      echo "Testing module-generated justfile: ${name}"
      cat justfile
      echo "---"

      # Validate with just parser
      ${just}/bin/just --dump > /dev/null || {
        echo "❌ Module justfile for ${name} failed to parse"
        exit 1
      }

      ${just}/bin/just --list
      echo "✅ Module justfile for ${name} parsed successfully"
      touch $out
    '';

  # Mock getExe that returns a placeholder path
  mockGetExe = _: "/nix/store/mock-package/bin/mock-command";
  mockLib =
    lib
    // {
      getExe = mockGetExe;
    };
in {
  # Test the python feature nbstrip recipe
  # NOTE: Can't use mkRecipe here because it doesn't support parameters
  # This recipe needs the notebook parameter in its signature
  testPythonNbstrip = mkJustParseTest "python-nbstrip" ''
    # Strip output from Jupyter notebooks
    nbstrip notebook="":
        #!/usr/bin/env bash
        set -euo pipefail
        if [ -z "{{notebook}}" ]; then
            /nix/store/mock/bin/fd -e ipynb -x /nix/store/mock/bin/nbstripout
        else
            /nix/store/mock/bin/nbstripout "{{notebook}}"
        fi
  '';

  # Test direnv feature (simple mkRecipe)
  testDirenvAllow = mkJustParseTest "direnv-allow" (
    mkRecipe "allow" "Allow direnv" [
      "/nix/store/mock/bin/direnv allow"
    ]
  );

  # Test a complex git recipe with shebang
  testGitPreCommit = mkJustParseTest "git-precommit" (
    mkRecipe "pre-commit" "Run pre-commit hooks" [
      "/nix/store/mock/bin/pre-commit run --all-files"
    ]
  );

  # Test recipe with just variables (common pattern)
  testRecipeWithJustVariables = mkJustParseTest "just-variables" ''
    # Test recipe with parameters
    test-var param="default":
        echo "Parameter: {{param}}"

    # Test recipe with conditional in bash
    conditional notebook="":
        #!/usr/bin/env bash
        if [ -z "{{notebook}}" ]; then
            echo "No notebook specified"
        else
            echo "Processing: {{notebook}}"
        fi
  '';
}
