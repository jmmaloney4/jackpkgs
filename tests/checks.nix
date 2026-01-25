{
  lib,
  inputs,
}: let
  system = "x86_64-linux";
  flakeParts = inputs.flake-parts.lib;
  checksModule = import ../modules/flake-parts/checks.nix {jackpkgsInputs = inputs;};

  pythonWorkspace = ./fixtures/checks/python-workspace;
  pythonWorkspaceDefault = ./fixtures/checks/python-workspace-default;
  pnpmWorkspace = ./fixtures/checks/pnpm-workspace;
  pnpmNoWorkspace = ./fixtures/checks/no-pnpm;

  # YAML parser test fixtures
  yamlTrailingWs = ./fixtures/checks/yaml-trailing-ws;
  yamlComments = ./fixtures/checks/yaml-comments;
  yamlMixedQuotes = ./fixtures/checks/yaml-mixed-quotes;

  # pyprojectPath is a string relative path, not a path object
  pythonWorkspacePyproject = "./pyproject.toml";
  pythonWorkspaceDefaultPyproject = "./pyproject.toml";

  optionsModule = {lib, ...}: let
    inherit (lib) mkOption types;
  in {
    options.jackpkgs = {
      python = {
        enable = mkOption {
          type = types.bool;
          default = false;
        };

        workspaceRoot = mkOption {
          type = types.nullOr types.path;
          default = null;
        };

        pyprojectPath = mkOption {
          type = types.nullOr types.str;
          default = null;
        };
      };

      pulumi = {
        enable = mkOption {
          type = types.bool;
          default = false;
        };
      };
    };
  };

  evalFlake = modules:
    flakeParts.evalFlakeModule {inherit inputs;} {
      systems = [system];
      imports = [optionsModule] ++ modules ++ [checksModule];
    };

  getChecks = modules: ((evalFlake modules).config.perSystem system).checks or {};

  getBuildCommand = drv: let
    attrs = drv.drvAttrs or {};
  in
    if attrs ? buildCommand
    then attrs.buildCommand
    else if attrs ? args
    then lib.last attrs.args
    else "";

  mkPythonWorkspaceStub = pkgs: {
    defaultSpec = {};
    mkEnv = {
      name,
      spec,
    }:
      pkgs.runCommand "python-env" {} ''
        mkdir -p $out/lib/python3.12/site-packages
        touch $out
      '';
  };

  perSystemArgs = projectRoot: {
    perSystem = {pkgs, ...}: {
      _module.args.pythonWorkspace = mkPythonWorkspaceStub pkgs;
      _module.args.jackpkgsProjectRoot = projectRoot;
    };
  };

  baseModule = {
    _module.check = false;
  };

  mkConfigModule = {
    pythonEnable ? false,
    pulumiEnable ? false,
    checksEnable ? null,
    pythonWorkspaceRoot ? pythonWorkspace,
    pyprojectPath ? pythonWorkspacePyproject,
    extraConfig ? {},
  }: let
    baseConfig = {
      jackpkgs = {
        python = {
          enable = pythonEnable;
          workspaceRoot = pythonWorkspaceRoot;
          pyprojectPath = pyprojectPath;
        };
        pulumi.enable = pulumiEnable;
      };
    };
    withChecksEnable =
      lib.optionalAttrs (checksEnable != null) {jackpkgs.checks.enable = checksEnable;};
  in
    lib.recursiveUpdate (lib.recursiveUpdate baseConfig withChecksEnable) extraConfig;

  mkChecks = {
    configModule,
    projectRoot ? pythonWorkspace,
  }: let
    eval = evalFlake [baseModule configModule (perSystemArgs projectRoot)];
    perSystemCfg = eval.config.perSystem system;
  in
    perSystemCfg.checks or {};

  hasInfixAll = needles: haystack: lib.all (n: lib.hasInfix n haystack) needles;
  hasChecksNamed = checks: names: lib.all (name: lib.hasAttr name checks) names;
  missingChecksNamed = checks: names: lib.all (name: !(lib.hasAttr name checks)) names;
  hasCheck = checks: name: lib.hasAttr name checks;
  missingCheck = checks: name: !(lib.hasAttr name checks);
in {
  testChecksEnabledByPythonDefault = let
    checks = mkChecks {
      configModule = mkConfigModule {pythonEnable = true;};
    };
  in {
    expr = hasChecksNamed checks ["python-pytest" "python-mypy" "python-ruff"];
    expected = true;
  };

  testChecksEnabledByPulumiDefault = let
    checks = mkChecks {
      configModule = mkConfigModule {
        pulumiEnable = true;
        extraConfig.jackpkgs.checks.typescript.tsc.packages = ["infra"];
      };
      projectRoot = pnpmNoWorkspace;
    };
  in {
    expr = hasCheck checks "typescript-tsc";
    expected = true;
  };

  testChecksDisabledGlobally = let
    checks = mkChecks {
      configModule = mkConfigModule {
        pythonEnable = true;
        pulumiEnable = true;
        checksEnable = false;
        extraConfig.jackpkgs.checks.typescript.tsc.packages = ["infra"];
      };
      projectRoot = pnpmNoWorkspace;
    };
  in {
    expr = missingChecksNamed checks ["python-pytest" "python-mypy" "python-ruff" "typescript-tsc"];
    expected = true;
  };

  testPythonWorkspaceDiscovery = let
    checks = mkChecks {
      configModule = mkConfigModule {pythonEnable = true;};
      projectRoot = pythonWorkspace;
    };
    script = getBuildCommand checks.python-pytest;
  in {
    expr =
      hasInfixAll ["/packages/pkg-a" "/packages/pkg-b" "/tools/cli"] script
      && !lib.hasInfix "/packages/ignored" script;
    expected = true;
  };

  testPythonWorkspaceDefaultMember = let
    checks = mkChecks {
      configModule = mkConfigModule {
        pythonEnable = true;
        pythonWorkspaceRoot = pythonWorkspaceDefault;
        pyprojectPath = pythonWorkspaceDefaultPyproject;
      };
      projectRoot = pythonWorkspaceDefault;
    };
    script = getBuildCommand checks.python-pytest;
  in {
    expr = lib.hasInfix "Checking ." script;
    expected = true;
  };

  testPythonPytestScript = let
    checks = mkChecks {
      configModule = mkConfigModule {
        pythonEnable = true;
        extraConfig.jackpkgs.checks.python.pytest.extraArgs = ["--color=yes" "-v"];
      };
    };
    script = getBuildCommand checks.python-pytest;
  in {
    expr =
      hasInfixAll ["PYTHONPATH=" "COVERAGE_FILE=" "pytest" "--color=yes" "-v"] script;
    expected = true;
  };

  testPythonMypyScript = let
    checks = mkChecks {
      configModule = mkConfigModule {
        pythonEnable = true;
        extraConfig.jackpkgs.checks.python.mypy.extraArgs = ["--strict"];
      };
    };
    script = getBuildCommand checks.python-mypy;
  in {
    expr =
      hasInfixAll ["PYTHONPATH=" "MYPY_CACHE_DIR=" "mypy" "--strict"] script;
    expected = true;
  };

  testPythonRuffScript = let
    checks = mkChecks {
      configModule = mkConfigModule {
        pythonEnable = true;
        extraConfig.jackpkgs.checks.python.ruff.extraArgs = ["--no-cache"];
      };
    };
    script = getBuildCommand checks.python-ruff;
  in {
    expr = hasInfixAll ["ruff check" "--no-cache"] script;
    expected = true;
  };

  testPythonDisableRuff = let
    checks = mkChecks {
      configModule = mkConfigModule {
        pythonEnable = true;
        extraConfig.jackpkgs.checks.python.ruff.enable = false;
      };
    };
  in {
    expr = missingCheck checks "python-ruff";
    expected = true;
  };

  testTypescriptWorkspaceDiscovery = let
    checks = mkChecks {
      configModule = mkConfigModule {
        pulumiEnable = true;
        extraConfig.jackpkgs.checks.typescript.tsc.extraArgs = ["--pretty" "false"];
      };
      projectRoot = pnpmWorkspace;
    };
    script = getBuildCommand checks.typescript-tsc;
  in {
    expr =
      hasInfixAll [
        "Type-checking packages/app"
        "Type-checking packages/lib"
        "Type-checking tools/cli"
        "tsc --noEmit"
        "--pretty"
      ]
      script
      && !lib.hasInfix "packages/ignored" script;
    expected = true;
  };

  testTypescriptMissingWorkspace = let
    checks = mkChecks {
      configModule = mkConfigModule {pulumiEnable = true;};
      projectRoot = pnpmNoWorkspace;
    };
  in {
    expr = missingCheck checks "typescript-tsc";
    expected = true;
  };

  testTypescriptPackageOverride = let
    checks = mkChecks {
      configModule = mkConfigModule {
        pulumiEnable = true;
        extraConfig.jackpkgs.checks.typescript.tsc.packages = ["infra" "tools/hello"];
      };
      projectRoot = pnpmNoWorkspace;
    };
    script = getBuildCommand checks.typescript-tsc;
  in {
    expr =
      hasInfixAll ["Type-checking infra" "Type-checking tools/hello"] script
      && !lib.hasInfix "packages/app" script;
    expected = true;
  };

  testTypescriptGuardMessage = let
    checks = mkChecks {
      configModule = mkConfigModule {
        pulumiEnable = true;
        extraConfig.jackpkgs.checks.typescript.tsc.packages = ["infra"];
      };
      projectRoot = pnpmNoWorkspace;
    };
    script = getBuildCommand checks.typescript-tsc;
  in {
    expr =
      hasInfixAll [
        "node_modules not found"
        "pnpm install"
        "jackpkgs.checks.typescript.enable = false"
      ]
      script;
    expected = true;
  };

  # YAML Parser Smoke Tests
  # These tests verify the YAML parser handles common edge cases correctly

  testYamlParserTrailingWhitespace = let
    # Test that trailing whitespace is trimmed from package paths
    # This was a bug fixed in commit 1ea2e81
    checks = mkChecks {
      configModule = mkConfigModule {
        pulumiEnable = true;
      };
      projectRoot = yamlTrailingWs;
    };
    script = getBuildCommand checks.typescript-tsc;
  in {
    expr =
      # Verify parser correctly discovers packages despite trailing whitespace in YAML
      hasInfixAll [
        "Type-checking packages/pkg1"
        "Type-checking packages/pkg2"
        "Type-checking tools/cli"
        "Type-checking apps/main"
      ]
      script;
    expected = true;
  };

  testYamlParserWithComments = let
    # Test that comments are properly ignored
    checks = mkChecks {
      configModule = mkConfigModule {
        pulumiEnable = true;
      };
      projectRoot = yamlComments;
    };
    script = getBuildCommand checks.typescript-tsc;
  in {
    expr =
      # Should find packages, tools, apps
      hasInfixAll [
        "Type-checking packages/pkg1"
        "Type-checking packages/pkg2"
        "Type-checking tools/cli"
        "Type-checking apps/main"
        "Type-checking apps/web"
      ]
      script
      # Should NOT include commented-out package
      && !lib.hasInfix "disabled/package" script;
    expected = true;
  };

  testYamlParserMixedQuoting = let
    # Test that unquoted, double-quoted, and single-quoted strings work
    checks = mkChecks {
      configModule = mkConfigModule {
        pulumiEnable = true;
      };
      projectRoot = yamlMixedQuotes;
    };
  in {
    expr = hasChecksNamed checks ["typescript-tsc"];
    expected = true;
  };

  testYamlParserGlobExpansion = let
    # Test that globs like "packages/*" are expanded correctly
    checks = mkChecks {
      configModule = mkConfigModule {
        pulumiEnable = true;
      };
      projectRoot = yamlMixedQuotes;
    };
    script = getBuildCommand checks.typescript-tsc;
  in {
    expr =
      # packages/* should expand to packages/pkg1 and packages/pkg2
      lib.hasInfix "Type-checking packages/pkg1" script
      && lib.hasInfix "Type-checking packages/pkg2" script
      # tools/* should expand to tools/cli
      && lib.hasInfix "Type-checking tools/cli" script
      # apps/* should expand to apps/main and apps/web
      && lib.hasInfix "Type-checking apps/main" script
      && lib.hasInfix "Type-checking apps/web" script
      # libs/core should be included as-is (no glob)
      && lib.hasInfix "Type-checking libs/core" script;
    expected = true;
  };

  testJestEnabled = let
    checks = mkChecks {
      configModule = mkConfigModule {
        extraConfig.jackpkgs.checks.enable = true;
        extraConfig.jackpkgs.checks.jest.enable = true;
        extraConfig.jackpkgs.checks.jest.packages = ["packages/app"];
      };
      projectRoot = pnpmWorkspace;
    };
  in {
    expr = hasCheck checks "javascript-jest";
    expected = true;
  };

  testJestScript = let
    checks = mkChecks {
      configModule = mkConfigModule {
        extraConfig.jackpkgs.checks.enable = true;
        extraConfig.jackpkgs.checks.jest.enable = true;
        extraConfig.jackpkgs.checks.jest.packages = ["packages/app"];
        extraConfig.jackpkgs.checks.jest.extraArgs = ["--coverage"];
      };
      projectRoot = pnpmWorkspace;
    };
    script = getBuildCommand checks.javascript-jest;
  in {
    expr = hasInfixAll [
      "Testing packages/app"
      "jest"
      "--coverage"
      "cp -r"
      "chmod -R +w"
    ] script;
    expected = true;
  };

  testNodeModulesLinking = let
    # Create a dummy derivation to simulate nodeModules
    dummyNodeModules = builtins.derivation {
      name = "dummy-node-modules";
      system = "x86_64-linux";
      builder = "/bin/sh";
      args = ["-c" "mkdir -p $out"];
    };
    checks = mkChecks {
      configModule = mkConfigModule {
        extraConfig.jackpkgs.checks.enable = true;
        extraConfig.jackpkgs.checks.jest.enable = true;
        extraConfig.jackpkgs.checks.jest.packages = ["packages/app"];
        extraConfig.jackpkgs.checks.jest.nodeModules = dummyNodeModules;
      };
      projectRoot = pnpmWorkspace;
    };
    script = getBuildCommand checks.javascript-jest;
  in {
    expr = hasInfixAll [
      "Linking node_modules"
      "ln -sfn"
      "/lib/node_modules"
      "cp -r"
    ] script;
    expected = true;
  };
}
