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

  pythonWorkspacePyproject =
    builtins.toPath (builtins.toString pythonWorkspace + "/pyproject.toml");
  pythonWorkspaceDefaultPyproject =
    builtins.toPath (builtins.toString pythonWorkspaceDefault + "/pyproject.toml");

  mkFlake = modules:
    flakeParts.mkFlake {inherit inputs;} {
      systems = [system];
      imports = [checksModule] ++ modules;
    };

  getChecks = modules: (mkFlake modules).checks.${system} or {};

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
    pkgs,
    lib,
    ...
  }: {
    _module.args = {
      pythonWorkspace = mkPythonWorkspaceStub pkgs;
      jackpkgsProjectRoot = projectRoot;
    };
    jackpkgs.python.pythonPackage = pkgs.python312;
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
  }:
    {
      jackpkgs.python.enable = pythonEnable;
      jackpkgs.python.workspaceRoot = pythonWorkspaceRoot;
      jackpkgs.python.pyprojectPath = pyprojectPath;
      jackpkgs.pulumi.enable = pulumiEnable;
    }
    // lib.optionalAttrs (checksEnable != null) {jackpkgs.checks.enable = checksEnable;}
    // extraConfig;

  mkChecks = {
    configModule,
    projectRoot ? pythonWorkspace,
  }:
    getChecks [baseModule configModule (perSystemArgs projectRoot)];

  hasInfixAll = needles: haystack: lib.all (n: lib.hasInfix n haystack) needles;
  hasChecksNamed = checks: names: lib.all (name: checks ? name) names;
  missingChecksNamed = checks: names: lib.all (name: !(checks ? name)) names;
  hasCheck = checks: name: checks ? name;
  missingCheck = checks: name: !(checks ? name);
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
}
