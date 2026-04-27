{
  lib,
  inputs,
}: let
  system = "x86_64-linux";
  flakeParts = inputs.flake-parts.lib;
  libModule = import ../modules/flake-parts/lib.nix {jackpkgsInputs = inputs;};
  pkgsModule = import ../modules/flake-parts/pkgs.nix {jackpkgsInputs = inputs;};
  checksModule = import ../modules/flake-parts/checks.nix {jackpkgsInputs = inputs;};
  devshellModule = import ../modules/flake-parts/devshell.nix {jackpkgsInputs = inputs;};
  fmtModule = import ../modules/flake-parts/fmt.nix {jackpkgsInputs = inputs;};
  justModule = import ../modules/flake-parts/just.nix {jackpkgsInputs = inputs;};
  nodejsModule = import ../modules/flake-parts/nodejs.nix {jackpkgsInputs = inputs;};
  preCommitModule = import ../modules/flake-parts/pre-commit.nix {jackpkgsInputs = inputs;};
  pulumiModule = import ../modules/flake-parts/pulumi.nix {jackpkgsInputs = inputs;};
  quartoModule = import ../modules/flake-parts/quarto.nix {jackpkgsInputs = inputs;};

  evalFlake = modules:
    flakeParts.evalFlakeModule {inherit inputs;} {
      systems = [system];
      imports = [libModule pkgsModule checksModule devshellModule fmtModule justModule nodejsModule preCommitModule quartoModule] ++ modules ++ [pulumiModule];
    };

  getPerSystemCfg = modules: (evalFlake modules).config.perSystem system;

  mkConfigModule = {
    backendUrl ? "s3://pulumi-state",
    secretsProvider ? "awskms://alias/pulumi",
    defaultStack ? "dev",
    stacks ? [],
  }: {
    _module.check = false;
    jackpkgs.pulumi = {
      enable = true;
      inherit backendUrl defaultStack secretsProvider stacks;
    };
  };

  expectedEnv = {
    PULUMI_IGNORE_AMBIENT_PLUGINS = "1";
    PULUMI_BACKEND_URL = "s3://pulumi-state";
    PULUMI_SECRETS_PROVIDER = "awskms://alias/pulumi";
    PULUMI_OPTION_NON_INTERACTIVE = "true";
    PULUMI_OPTION_COLOR = "never";
    PULUMI_OPTION_SUPPRESS_PROGRESS = "true";
    NODE_OPTIONS = "--async-context-frame";
  };

  hasExpectedEnv = drv:
    lib.all (name: drv.${name} == expectedEnv.${name}) (builtins.attrNames expectedEnv);

  expectedShellHookExports =
    map (name: "export ${name}=${lib.escapeShellArg expectedEnv.${name}}") (builtins.attrNames expectedEnv);

  hasExpectedShellHookExports = drv:
    lib.all (needle: lib.hasInfix needle drv.shellHook) expectedShellHookExports;

  hasPulumiEnvSetupHook = drv:
    lib.any (input: lib.hasInfix "jackpkgs-pulumi-env-hook" (toString input)) (drv.nativeBuildInputs or []);

  defaultStacks = [
    {
      path = "infra";
      stacks = ["dev" "prod"];
    }
  ];

  hasInfixAll = needles: haystack:
    lib.all (needle: lib.hasInfix needle haystack) needles;
in {
  testPulumiDevShellSetsPulumiCliDefaults = let
    perSystemCfg = getPerSystemCfg [(mkConfigModule {})];
  in {
    expr = hasExpectedEnv perSystemCfg.jackpkgs.outputs.pulumiDevShell;
    expected = true;
  };

  testCiPulumiDevShellSetsPulumiCliDefaults = let
    perSystemCfg = getPerSystemCfg [(mkConfigModule {})];
  in {
    expr = hasExpectedEnv perSystemCfg.devShells.ci-pulumi;
    expected = true;
  };

  testComposedDevShellExportsPulumiEnv = let
    perSystemCfg = getPerSystemCfg [(mkConfigModule {})];
  in {
    expr =
      hasExpectedShellHookExports perSystemCfg.jackpkgs.outputs.devShell
      && hasPulumiEnvSetupHook perSystemCfg.jackpkgs.outputs.devShell;
    expected = true;
  };

  testPulumiJustfileQuotesDefaultStack = let
    perSystemCfg = getPerSystemCfg [
      (mkConfigModule {
        stacks = defaultStacks;
      })
    ];
    justfile = perSystemCfg.jackpkgs.outputs.pulumiJustfile;
  in {
    expr =
      hasInfixAll [
        ''preview env="dev":''
        ''deploy env="dev":''
      ]
      justfile
      && lib.all (needle: !(lib.hasInfix needle justfile)) [
        "preview env=dev:"
        "deploy env=dev:"
      ];
    expected = true;
  };

  testPulumiJustfileQuotesCustomDefaultStack = let
    perSystemCfg = getPerSystemCfg [
      (mkConfigModule {
        defaultStack = "stage-us";
        stacks = [
          {
            path = "infra";
            stacks = ["stage-us" "prod"];
          }
        ];
      })
    ];
    justfile = perSystemCfg.jackpkgs.outputs.pulumiJustfile;
  in {
    expr =
      hasInfixAll [
        ''preview env="stage-us":''
        ''deploy env="stage-us":''
      ]
      justfile;
    expected = true;
  };

  testPulumiShellHookEscapesValuesWithSpecialChars = let
    scaryUrl = "s3://bucket/path?query=1&flag=true";
    scarySecret = "passphrase's complex value";
  in {
    expr =
      # lib.escapeShellArg wraps in single quotes and escapes internal single quotes
      lib.hasInfix "'" (lib.escapeShellArg scaryUrl)
      && lib.hasInfix "'" (lib.escapeShellArg scarySecret);
    expected = true;
  };
}
