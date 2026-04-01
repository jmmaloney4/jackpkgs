{
  lib,
  inputs,
}: let
  system = "x86_64-linux";
  flakeParts = inputs.flake-parts.lib;
  libModule = import ../modules/flake-parts/lib.nix {jackpkgsInputs = inputs;};
  pkgsModule = import ../modules/flake-parts/pkgs.nix {jackpkgsInputs = inputs;};
  devshellModule = import ../modules/flake-parts/devshell.nix {jackpkgsInputs = inputs;};
  gcpModule = import ../modules/flake-parts/gcp.nix {jackpkgsInputs = inputs;};
  pulumiModule = import ../modules/flake-parts/pulumi.nix {jackpkgsInputs = inputs;};

  evalFlake = modules:
    flakeParts.evalFlakeModule {inherit inputs;} {
      systems = [system];
      imports = [libModule pkgsModule devshellModule gcpModule] ++ modules ++ [pulumiModule];
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
  };

  hasExpectedEnv = drv:
    lib.all (name: drv.${name} == expectedEnv.${name}) (builtins.attrNames expectedEnv);

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
}
