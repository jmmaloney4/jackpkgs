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
    false
  );

  # Test direnv feature pattern (simple mkRecipe)
  testDirenvAllow = mkJustParseTest "direnv-allow" (
    mkRecipe "allow" "Allow direnv" [
      "${lib.getExe mockPackages.direnv} allow"
    ]
    false
  );

  # Test git pre-commit recipe pattern
  testGitPreCommit = mkJustParseTest "git-precommit" (
    mkRecipe "pre-commit" "Run pre-commit hooks" [
      "${lib.getExe mockPackages.pre-commit} run --all-files"
    ]
    false
  );

  # Test Node.js pnpm hash update recipe pattern
  testNodejsUpdatePnpmHash = mkJustParseTest "nodejs-update-pnpm-hash" ''
    # Refresh pnpm-lock.yaml and update pnpmDepsHash in flake.nix
    update-pnpm-hash:
        #!/usr/bin/env bash
        set -euo pipefail

        flake="flake.nix"
        backup=$(mktemp)
        build_log=$(mktemp)
        updated=0

        cp "$flake" "$backup"
        trap 'rm -f "$build_log"; if [ "$updated" -eq 0 ]; then mv "$backup" "$flake"; else rm -f "$backup"; fi' EXIT

        echo "📦 Running pnpm install to refresh pnpm-lock.yaml..."
        pnpm install

        system=$(nix eval --raw --impure --expr 'builtins.currentSystem')

        echo "🔍 Detecting system: $system"
        echo "📝 Setting temporary fake hash to trigger nix hash mismatch..."
        node -e 'const fs = require("node:fs"); const path = process.argv[1]; const contents = fs.readFileSync(path, "utf8"); const pattern = /^[ \t]*#?[ \t]*pnpmDepsHash = .*$/m; if (!pattern.test(contents)) { throw new Error("Could not locate pnpmDepsHash in flake.nix"); } fs.writeFileSync(path, contents.replace(pattern, "        pnpmDepsHash = \"sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\";"));' "$flake"

        echo "🔨 Building devshell to fetch new hash..."
        nix build ".#devShells.''${system}.default" >"$build_log" 2>&1 || true
        new_hash=$(node -e 'const fs = require("node:fs"); const log = fs.readFileSync(process.argv[1], "utf8"); const match = log.match(/got:\s*(sha256-[A-Za-z0-9+/=]+)/); if (match) { process.stdout.write(match[1]); }' "$build_log")

        if [ -z "$new_hash" ]; then
            echo "❌ Could not extract new hash from nix output"
            echo "Output was:"
            cat "$build_log"
            exit 1
        fi

        echo "✅ New hash: $new_hash"
        echo "📝 Updating $flake..."
        NEW_HASH="$new_hash" node -e 'const fs = require("node:fs"); const path = process.argv[1]; const contents = fs.readFileSync(path, "utf8"); const pattern = /^[ \t]*#?[ \t]*pnpmDepsHash = .*$/m; if (!pattern.test(contents)) { throw new Error("Could not locate pnpmDepsHash in flake.nix"); } fs.writeFileSync(path, contents.replace(pattern, "        pnpmDepsHash = \"" + process.env.NEW_HASH + "\";"));' "$flake"
        updated=1

        echo "✅ Done! pnpmDepsHash updated to $new_hash"

    # alias for update-pnpm-hash
    update-pnpm-deps:
        @just update-pnpm-hash
  '';

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

  # Test auth-status recipe pattern with CLOUDSDK_CONFIG variable
  testAuthStatus = mkJustParseTest "auth-status" ''
    # Show current GCP authentication status
    auth-status:
        #!/usr/bin/env bash
        echo "Profile:  ''${CLOUDSDK_CONFIG:-~/.config/gcloud (default)}"
        echo "Account:  $(${mockGetExe null} config get-value account 2>/dev/null || echo 'not set')"
        echo "Project:  $(${mockGetExe null} config get-value project 2>/dev/null || echo 'not set')"
        if ${mockGetExe null} auth print-access-token --quiet >/dev/null 2>&1; then
            echo "Token:    valid"
        else
            echo "Token:    EXPIRED — run 'just auth'"
        fi
  '';
}
