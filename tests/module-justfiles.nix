{
  lib,
  pkgs,
  testHelpers,
}: let
  just = pkgs.just;
  inherit (testHelpers.justHelpers) mkRecipe mkRecipeWithParams;

  # NOTE: These tests validate recipe PATTERNS and justfile SYNTAX, not actual
  # module output. They test that common patterns used in modules (shebang recipes,
  # parameters, conditionals) generate valid justfile syntax that just can parse.
  #
  # To test actual module output, we would need to evaluate the modules with mock
  # configuration (tracked in future work - see tracking issue).
  #
  # These tests use the same helper functions (mkRecipe, mkRecipeWithParams) that
  # the actual modules use, ensuring we test the same API.

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

  # Mock packages for generating realistic paths
  mockPackages = {
    fd = pkgs.writeShellScriptBin "fd" "echo 'mock fd'";
    nbstripout = pkgs.writeShellScriptBin "nbstripout" "echo 'mock nbstripout'";
    direnv = pkgs.writeShellScriptBin "direnv" "echo 'mock direnv'";
    pre-commit = pkgs.writeShellScriptBin "pre-commit" "echo 'mock pre-commit'";
  };

  # Mock getExe that returns a placeholder path
  mockGetExe = _: "/nix/store/mock-package/bin/mock-command";
  mockLib =
    lib
    // {
      getExe = mockGetExe;
    };
in {
  # Test the python feature nbstrip recipe pattern
  testPythonNbstrip = mkJustParseTest "python-nbstrip" (
    mkRecipeWithParams "nbstrip" [''notebook=""''] "Strip output from Jupyter notebooks" [
      "#!/usr/bin/env bash"
      "set -euo pipefail"
      ''if [ -z "{{notebook}}" ]; then''
      "    ${lib.getExe mockPackages.fd} -e ipynb -x ${lib.getExe mockPackages.nbstripout}"
      "else"
      "    ${lib.getExe mockPackages.nbstripout} \"{{notebook}}\""
      "fi"
    ]
  );

  # Test direnv feature pattern (simple mkRecipe)
  testDirenvAllow = mkJustParseTest "direnv-allow" (
    mkRecipe "allow" "Allow direnv" [
      "${lib.getExe mockPackages.direnv} allow"
    ]
  );

  # Test git pre-commit recipe pattern
  testGitPreCommit = mkJustParseTest "git-precommit" (
    mkRecipe "pre-commit" "Run pre-commit hooks" [
      "${lib.getExe mockPackages.pre-commit} run --all-files"
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

  # Test infra auth recipe pattern with GCP account variable
  # This tests that variable assignment with default values works with just's shell
  # Uses shebang to ensure commands run in the same shell
  testInfraAuthWithGcpAccount = mkJustParseTest "infra-auth-gcp" ''
    # Authenticate with GCP and refresh ADC
    # (set GCP_ACCOUNT_USER to override username)
    auth:
        #!/usr/bin/env bash
        GCP_ACCOUNT_USER="''${GCP_ACCOUNT_USER:-$USER}"
        ${mockGetExe null} auth login --update-adc --account=$GCP_ACCOUNT_USER@example.com
  '';

  # Test infra auth recipe without iamOrg (simpler, no shebang needed)
  testInfraAuthWithoutGcpAccount = mkJustParseTest "infra-auth-simple" ''
    # Authenticate with GCP and refresh ADC
    # (set GCP_ACCOUNT_USER to override username)
    auth:
        ${mockGetExe null} auth login --update-adc
  '';
}
