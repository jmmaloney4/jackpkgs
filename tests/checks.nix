{
  lib,
  inputs,
}: let
  system = "x86_64-linux";
  flakeParts = inputs.flake-parts.lib;
  libModule = import ../modules/flake-parts/lib.nix {jackpkgsInputs = inputs;};
  checksModule = import ../modules/flake-parts/checks.nix {jackpkgsInputs = inputs;};

  pythonWorkspace = ./fixtures/checks/python-workspace;
  pythonWorkspaceDefault = ./fixtures/checks/python-workspace-default;
  pnpmWorkspace = ./fixtures/checks/pnpm-workspace;
  pnpmWorkspaceYml = ./fixtures/checks/pnpm-workspace-yml;
  noWorkspaceFixture = ./fixtures/checks/no-workspace;

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

        environments = mkOption {
          type = types.attrsOf (types.submodule {
            options = {
              name = mkOption {
                type = types.str;
              };
              editable = mkOption {
                type = types.bool;
                default = false;
              };
              includeGroups = mkOption {
                type = types.nullOr types.bool;
                default = null;
              };
            };
          });
          default = {};
        };
      };

      pulumi = {
        enable = mkOption {
          type = types.bool;
          default = false;
        };
      };

      outputs.pythonEnvironments = mkOption {
        type = types.attrsOf types.unspecified;
        default = {};
      };
    };
  };

  evalFlake = modules:
    flakeParts.evalFlakeModule {inherit inputs;} {
      systems = [system];
      imports = [optionsModule libModule moduleArgs] ++ modules ++ [checksModule];
    };

  evalFlakeNoMock = modules:
    flakeParts.evalFlakeModule {inherit inputs;} {
      systems = [system];
      imports = [optionsModule libModule] ++ modules ++ [checksModule];
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
    computeSpec = {includeGroups ? false}:
      if includeGroups
      then {_groups = true;}
      else {};
  };

  perSystemArgs = projectRoot: {
    perSystem = {pkgs, ...}: {
      _module.args.pythonWorkspace = mkPythonWorkspaceStub pkgs;
      _module.args.jackpkgsProjectRoot = projectRoot;
    };
  };

  mockFromYAML = yamlFile: let
    pnpmWorkspaceYaml = {
      packages = ["packages/*" "tools/*"];
    };
  in
    if builtins.baseNameOf yamlFile == "pnpm-workspace.yaml"
    then pnpmWorkspaceYaml
    else {};

  moduleArgs = {
    jackpkgs.checks.fromYAML = mockFromYAML;
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

  mkChecksNoMock = {
    configModule,
    projectRoot ? pythonWorkspace,
  }: let
    eval = evalFlakeNoMock [baseModule configModule (perSystemArgs projectRoot)];
    perSystemCfg = eval.config.perSystem system;
  in
    perSystemCfg.checks or {};

  hasInfixAll = needles: haystack: lib.all (n: lib.hasInfix n haystack) needles;
  hasChecksNamed = checks: names: lib.all (name: lib.hasAttr name checks) names;
  missingChecksNamed = checks: names: lib.all (name: !(lib.hasAttr name checks)) names;
  hasCheck = checks: name: lib.hasAttr name checks;
  missingCheck = checks: name: !(lib.hasAttr name checks);

  # Dummy nodeModules derivation used by script-generation tests
  dummyNodeModules = builtins.derivation {
    name = "dummy-node-modules";
    system = "x86_64-linux";
    builder = "/bin/sh";
    args = ["-c" "mkdir -p $out"];
  };
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
      projectRoot = noWorkspaceFixture;
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
      projectRoot = noWorkspaceFixture;
    };
  in {
    expr = missingChecksNamed checks ["python-pytest" "python-mypy" "python-ruff" "python-numpydoc" "typescript-tsc"];
    expected = true;
  };

  testPythonNumpydocDisabledByDefault = let
    checks = mkChecks {
      configModule = mkConfigModule {pythonEnable = true;};
    };
  in {
    expr = missingCheck checks "python-numpydoc";
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

  testPythonNumpydocScript = let
    checks = mkChecks {
      configModule = mkConfigModule {
        pythonEnable = true;
        extraConfig.jackpkgs.checks.python.numpydoc = {
          enable = true;
          extraArgs = ["--checks" "all" "--exclude" "GL08"];
        };
      };
    };
    script = getBuildCommand checks.python-numpydoc;
  in {
    expr =
      hasInfixAll [
        "PYTHONPATH="
        "python -m numpydoc.hooks.validate_docstrings"
        "--checks"
        "all"
        "--exclude"
        "GL08"
      ]
      script;
    expected = true;
  };

  testPythonRuffDefaultHasNoCache = let
    checks = mkChecks {
      configModule = mkConfigModule {pythonEnable = true;};
    };
    script = getBuildCommand checks.python-ruff;
  in {
    expr = hasInfixAll ["ruff check" "--no-cache"] script;
    expected = true;
  };

  testPythonRuffSetsCacheDir = let
    checks = mkChecks {
      configModule = mkConfigModule {pythonEnable = true;};
    };
    script = getBuildCommand checks.python-ruff;
  in {
    expr = hasInfixAll ["RUFF_CACHE_DIR=$TMPDIR"] script;
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

  testPythonCiEnvSelectionWithGroups = let
    # Test that CI env selection prefers environments with includeGroups = true
    checks = mkChecks {
      configModule = mkConfigModule {
        pythonEnable = true;
        extraConfig = {
          jackpkgs.python.environments = {
            # Non-editable env without groups (should NOT be selected)
            prod = {
              name = "python-prod";
              editable = false;
              includeGroups = false;
            };
            # Non-editable env with groups (should be selected)
            ci = {
              name = "python-ci";
              editable = false;
              includeGroups = true;
            };
          };
        };
      };
    };
    script = getBuildCommand checks.python-pytest;
  in {
    # Verify that pytest runs (which means an env with groups was found/created)
    expr = lib.hasInfix "pytest" script;
    expected = true;
  };

  testPythonCiEnvSelectionDevPriority = let
    # Test that 'dev' env is prioritized if it's non-editable with groups
    checks = mkChecks {
      configModule = mkConfigModule {
        pythonEnable = true;
        extraConfig = {
          jackpkgs.python.environments = {
            # Non-editable dev env with groups (should be selected as priority 1)
            dev = {
              name = "python-dev-ci";
              editable = false;
              includeGroups = true;
            };
            # Another non-editable env with groups
            ci = {
              name = "python-ci";
              editable = false;
              includeGroups = true;
            };
          };
        };
      };
    };
    script = getBuildCommand checks.python-pytest;
  in {
    # Verify that pytest runs (which means dev env was selected)
    expr = lib.hasInfix "pytest" script;
    expected = true;
  };

  testPythonCiEnvSelectionEditableIgnored = let
    # Test that editable environments are NOT selected for CI even with groups
    checks = mkChecks {
      configModule = mkConfigModule {
        pythonEnable = true;
        extraConfig = {
          jackpkgs.python.environments = {
            # Editable env with groups (should NOT be selected)
            dev = {
              name = "python-dev";
              editable = true;
              includeGroups = true;
            };
          };
        };
      };
    };
    script = getBuildCommand checks.python-pytest;
  in {
    # Verify that pytest still runs (auto-created CI env should be used)
    expr = lib.hasInfix "pytest" script;
    expected = true;
  };

  testPythonCiEnvSelectionNoGroupsFallback = let
    # Test that auto-created CI env is used when no suitable env exists
    checks = mkChecks {
      configModule = mkConfigModule {
        pythonEnable = true;
        extraConfig = {
          jackpkgs.python.environments = {
            # Non-editable env without groups (should NOT be selected)
            prod = {
              name = "python-prod";
              editable = false;
              includeGroups = false;
            };
          };
        };
      };
    };
    script = getBuildCommand checks.python-pytest;
  in {
    # Verify that pytest runs (auto-created CI env should be used)
    expr = lib.hasInfix "pytest" script;
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
      projectRoot = noWorkspaceFixture;
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
      projectRoot = noWorkspaceFixture;
    };
    script = getBuildCommand checks.typescript-tsc;
  in {
    expr =
      hasInfixAll ["Type-checking infra" "Type-checking tools/hello"] script
      && !lib.hasInfix "packages/app" script;
    expected = true;
  };

  testTypescriptRejectsNegationWorkspacePattern = let
    result = builtins.tryEval (
      (mkChecksNoMock {
        configModule = mkConfigModule {
          pulumiEnable = true;
          extraConfig.jackpkgs.checks.fromYAML = _: {
            packages = ["packages/*" "!packages/ignored"];
          };
        };
        projectRoot = pnpmWorkspace;
      }).typescript-tsc
    );
  in {
    expr = result.success;
    expected = false;
  };

  testTypescriptDiscoversPackagesFromYmlJsonSibling = let
    checks = mkChecksNoMock {
      configModule = mkConfigModule {
        pulumiEnable = true;
      };
      projectRoot = pnpmWorkspaceYml;
    };
    script = getBuildCommand checks.typescript-tsc;
  in {
    expr = hasInfixAll ["Type-checking packages/app" "Type-checking packages/lib"] script;
    expected = true;
  };

  testTypescriptGuardMessage = let
    checks = mkChecks {
      configModule = mkConfigModule {
        pulumiEnable = true;
        extraConfig.jackpkgs.checks.typescript.tsc.packages = ["infra"];
      };
      projectRoot = noWorkspaceFixture;
    };
    script = getBuildCommand checks.typescript-tsc;
  in {
    expr =
      hasInfixAll [
        "node_modules not found"
        "jackpkgs.nodejs.enable = true"
        "jackpkgs.checks.typescript.enable = false"
      ]
      script
      && !lib.hasInfix "Linking node_modules from" script;
    expected = true;
  };

  testTypescriptScriptWithNodeModules = let
    checks = mkChecks {
      configModule = mkConfigModule {
        pulumiEnable = true;
        extraConfig = {
          jackpkgs.checks.typescript.tsc.packages = ["packages/app" "tools/cli"];
          jackpkgs.checks.typescript.tsc.nodeModules = dummyNodeModules;
        };
      };
      projectRoot = pnpmWorkspace;
    };
    script = getBuildCommand checks.typescript-tsc;
  in {
    expr =
      hasInfixAll [
        "Linking node_modules from $nm_store..."
        ''ln -sfn "$nm_root" node_modules''
        ''if [ -d "$nm_store"/''
        ''ln -sfn "$nm_store"/''
        ''elif [ -d "$nm_root"/''
        ''ln -sfn "$nm_root"/''
        "packages/app/node_modules"
        "tools/cli/node_modules"
        ''if [ ! -d "node_modules" ] && [ ! -d ''
      ]
      script
      && !lib.hasInfix "$PWD/node_modules/.bin" script;
    expected = true;
  };

  testTypescriptNodeModulesLinkingIncludesDiscoveredPackages = let
    checks = mkChecks {
      configModule = mkConfigModule {
        pulumiEnable = true;
        extraConfig.jackpkgs.checks.typescript.tsc.nodeModules = dummyNodeModules;
      };
      projectRoot = pnpmWorkspace;
    };
    script = getBuildCommand checks.typescript-tsc;
  in {
    expr =
      hasInfixAll [
        ''if [ -d "$nm_store"/''
        "packages/app/node_modules"
        "packages/lib/node_modules"
        "tools/cli/node_modules"
        ''elif [ -d "$nm_root"/''
      ]
      script;
    expected = true;
  };

  testVitestEnabled = let
    checks = mkChecks {
      configModule = mkConfigModule {
        extraConfig.jackpkgs.checks.enable = true;
        extraConfig.jackpkgs.checks.vitest.enable = true;
        extraConfig.jackpkgs.checks.vitest.packages = ["packages/app"];
      };
      projectRoot = pnpmWorkspace;
    };
  in {
    expr = hasCheck checks "javascript-vitest";
    expected = true;
  };

  testVitestScript = let
    checks = mkChecks {
      configModule = mkConfigModule {
        extraConfig.jackpkgs.checks.enable = true;
        extraConfig.jackpkgs.checks.vitest.enable = true;
        extraConfig.jackpkgs.checks.vitest.packages = ["packages/app"];
        extraConfig.jackpkgs.checks.vitest.extraArgs = ["--coverage"];
      };
      projectRoot = pnpmWorkspace;
    };
    script = getBuildCommand checks.javascript-vitest;
  in {
    # Note: When nodeModules is null, no PATH export is generated (security: no source-tree binaries)
    expr =
      hasInfixAll [
        "Testing packages/app"
        "vitest"
        "--coverage"
        "cp -R"
        "chmod -R +w"
        "cd src"
      ]
      script
      && !lib.hasInfix "Linking node_modules from" script;
    expected = true;
  };

  # Test that PATH is set to Nix store binaries when nodeModules is provided
  testVitestScriptWithNodeModules = let
    checks = mkChecks {
      configModule = mkConfigModule {
        extraConfig.jackpkgs.checks.enable = true;
        extraConfig.jackpkgs.checks.vitest.enable = true;
        extraConfig.jackpkgs.checks.vitest.packages = ["packages/app"];
        extraConfig.jackpkgs.checks.vitest.nodeModules = dummyNodeModules;
      };
      projectRoot = pnpmWorkspace;
    };
    script = getBuildCommand checks.javascript-vitest;
  in {
    # Verify PATH is set to Nix store binaries (trusted only, not source tree)
    expr =
      hasInfixAll [
        "Testing packages/app"
        "/node_modules/.bin"
        "export PATH="
      ]
      script
      # Also verify source-tree PATH is NOT added
      && !(lib.hasInfix "$PWD/node_modules/.bin" script);
    expected = true;
  };

  testNodeModulesLinking = let
    checks = mkChecks {
      configModule = mkConfigModule {
        extraConfig.jackpkgs.checks.enable = true;
        extraConfig.jackpkgs.checks.vitest.enable = true;
        extraConfig.jackpkgs.checks.vitest.packages = ["packages/app"];
        extraConfig.jackpkgs.checks.vitest.nodeModules = dummyNodeModules;
      };
      projectRoot = pnpmWorkspace;
    };
    script = getBuildCommand checks.javascript-vitest;
  in {
    expr =
      hasInfixAll [
        "Linking node_modules"
        ''ln -sfn "$nm_root" node_modules''
        ''if [ -d "$nm_store"/''
        ''ln -sfn "$nm_store"/''
        ''elif [ -d "$nm_root"/''
        ''ln -sfn "$nm_root"/''
        "packages/app/node_modules"
        "cp -R"
      ]
      script;
    expected = true;
  };

  # Test that check derivations actually build successfully
  # This catches issues that script inspection misses (e.g., broken shell syntax, missing dependencies)
  testCheckDerivationBuilds = let
    # Create a minimal Python workspace fixture for testing
    minimalPythonCheck = mkChecks {
      configModule = mkConfigModule {
        pythonEnable = true;
        checksEnable = true;
        extraConfig.jackpkgs.checks.python.pytest.enable = true;
        extraConfig.jackpkgs.checks.python.mypy.enable = false;
        extraConfig.jackpkgs.checks.python.ruff.enable = false;
      };
      projectRoot = pythonWorkspace;
    };
  in {
    # Verify the check is a valid derivation
    expr = lib.isDerivation minimalPythonCheck.python-pytest;
    expected = true;
  };
}
