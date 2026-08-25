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
    nodejsEnable ? false,
  }: {
    _module.check = false;
    perSystem = {pkgs, ...}: {
      packages."adr-conflict-check" = pkgs.writeShellScriptBin "adr-conflict-check" "";
    };
    jackpkgs.nodejs = lib.mkIf nodejsEnable {
      enable = true;
      pnpmDepsHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
      projectRoot = ../.;
    };
    jackpkgs.pulumi = {
      enable = true;
      inherit backendUrl defaultStack secretsProvider stacks;
    };
  };

  hasPulumiEnvSetupHook = hookName: drv:
    lib.any (input: lib.hasInfix hookName (toString input)) (drv.nativeBuildInputs or []);

  defaultStacks = [
    {
      path = "infra";
      stacks = ["dev" "prod"];
    }
  ];

  hasInfixAll = needles: haystack:
    lib.all (needle: lib.hasInfix needle haystack) needles;

  mkPluginsModule = plugins: {
    perSystem = {pkgs, ...}: {
      jackpkgs.pulumi.plugins = map (pl: pl // {package = pkgs.hello;}) plugins;
    };
  };
in {
  testPulumiDevShellSetsPulumiCliDefaults = let
    perSystemCfg = getPerSystemCfg [(mkConfigModule {})];
  in {
    expr = hasPulumiEnvSetupHook "jackpkgs-pulumi-env-hook" perSystemCfg.jackpkgs.outputs.pulumiDevShell;
    expected = true;
  };

  testCiPulumiDevShellSetsPulumiCliDefaults = let
    perSystemCfg = getPerSystemCfg [(mkConfigModule {})];
  in {
    expr = hasPulumiEnvSetupHook "jackpkgs-ci-pulumi-env-hook" perSystemCfg.devShells.ci-pulumi;
    expected = true;
  };

  testComposedDevShellExportsPulumiEnv = let
    perSystemCfg = getPerSystemCfg [(mkConfigModule {})];
  in {
    expr = hasPulumiEnvSetupHook "jackpkgs-pulumi-env-hook" perSystemCfg.jackpkgs.outputs.devShell;
    expected = true;
  };

  testCiPulumiPackagesIncludePnpmWhenNodejsEnabled = let
    perSystemCfg = getPerSystemCfg [(mkConfigModule {nodejsEnable = true;})];
  in {
    expr = builtins.elem perSystemCfg.jackpkgs.nodejs.pnpmPackage perSystemCfg.jackpkgs.pulumi.ci.packages;
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

  # just does not pass recipe parameters as positional args to shebang recipes
  # unless `set positional-arguments` is declared, so a body reading
  # `env="${1:-dev}"` always saw the default and `just deploy prod` silently
  # rolled dev. The recipes must interpolate the parameter via just instead.
  testPulumiJustfileInterpolatesEnvParameter = let
    perSystemCfg = getPerSystemCfg [
      (mkConfigModule {
        stacks = defaultStacks;
      })
    ];
    justfile = perSystemCfg.jackpkgs.outputs.pulumiJustfile;
  in {
    expr =
      lib.count (lib.hasInfix "env={{quote(env)}}") (lib.splitString "\n" justfile)
      == 2 # once in preview, once in deploy
      && !(lib.hasInfix "\${1:-" justfile);
    expected = true;
  };

  testPulumiPreviewHasSummaryFunctionAndOutput = let
    perSystemCfg = getPerSystemCfg [
      (mkConfigModule {
        stacks = defaultStacks;
      })
    ];
    justfile = perSystemCfg.jackpkgs.outputs.pulumiJustfile;
  in {
    expr =
      hasInfixAll [
        "run_preview()"
        "preview_summaries=()"
        "preview_summaries+=(\"\${project_path} (\${stack_name})"
        "📊 Preview summary:"
        "for summary in \"\${preview_summaries[@]}\""
      ]
      justfile;
    expected = true;
  };

  testPulumiPreviewUsesRunPreviewFunction = let
    perSystemCfg = getPerSystemCfg [
      (mkConfigModule {
        stacks = defaultStacks;
      })
    ];
    justfile = perSystemCfg.jackpkgs.outputs.pulumiJustfile;
    # The preview recipe ends before the deploy recipe begins.
    previewSection = lib.head (lib.splitString "\ndeploy " justfile);
  in {
    expr =
      # The function is defined once in the preview recipe body.
      lib.count (lib.hasInfix "run_preview") (lib.splitString "\n" previewSection)
      >= 3; # function definition + 1 call site (single-stack default config)
    expected = true;
  };

  testPulumiPreviewSummaryFormat = let
    perSystemCfg = getPerSystemCfg [
      (mkConfigModule {
        stacks = defaultStacks;
      })
    ];
    justfile = perSystemCfg.jackpkgs.outputs.pulumiJustfile;
  in {
    # Summary line format: path (stack) +N/+-N/~N/-N
    expr = lib.hasInfix "+\${create_count}/+-\${replace_count}/~\${update_count}/-\${delete_count}" justfile;
    expected = true;
  };

  # Previously, run_preview's non-zero return (project preview failure) was
  # called as a bare statement, so `set -euo pipefail` aborted the whole
  # recipe on the first failing project — every project after it in the
  # list was silently never previewed. deploy already guards its per-project
  # command with `if ! ...; then failed_stacks+=(...); fi`; preview must do
  # the same with run_preview so one broken project doesn't hide the rest.
  testPulumiPreviewContinuesPastFailedProject = let
    perSystemCfg = getPerSystemCfg [
      (mkConfigModule {
        stacks = defaultStacks;
      })
    ];
    justfile = perSystemCfg.jackpkgs.outputs.pulumiJustfile;
    previewSection = lib.head (lib.splitString "\ndeploy " justfile);
  in {
    expr =
      hasInfixAll [
        "failed_previews=()"
        "if ! run_preview"
        "failed_previews+=("
        "❌ Failed previews:"
      ]
      previewSection
      # run_preview's return value must never be called as a bare statement
      # (unguarded), or `set -e` aborts the recipe on the first failure.
      && !(lib.hasInfix "    run_preview \"\$project_path\" \"\$_effective_stack\"" previewSection)
      && !(lib.hasInfix "    run_preview \"\$project_path\" \"\$env\"" previewSection);
    expected = true;
  };

  testPulumiPreviewExitsNonZeroOnlyWhenAProjectFailed = let
    perSystemCfg = getPerSystemCfg [
      (mkConfigModule {
        stacks = defaultStacks;
      })
    ];
    justfile = perSystemCfg.jackpkgs.outputs.pulumiJustfile;
    previewSection = lib.head (lib.splitString "\ndeploy " justfile);
  in {
    expr =
      hasInfixAll [
        "if [ \${#failed_previews[@]} -eq 0 ]; then"
        "exit 0"
        "exit 1"
      ]
      previewSection;
    expected = true;
  };

  # jackpkgs#380: a bare `ln -sfn` into $PULUMI_HOME/plugins is invisible to
  # the Nix garbage collector, so a GC that runs between shell entries can
  # collect a still-pinned plugin's store path and leave Pulumi with a
  # dangling symlink. The shellHook must register a GC root before linking.
  testPulumiDevShellRegistersPluginGcRoot = let
    perSystemCfg = getPerSystemCfg [
      (mkConfigModule {})
      (mkPluginsModule [
        {
          name = "sector7";
          version = "0.20.14";
        }
      ])
    ];
    shellHook = perSystemCfg.jackpkgs.outputs.pulumiDevShell.shellHook;
  in {
    expr =
      hasInfixAll [
        "nix-store"
        "--realise"
        "--add-root"
        "--indirect"
        "resource-sector7-v0.20.14"
      ]
      shellHook;
    expected = true;
  };

  testCiPulumiDevShellRegistersPluginGcRoot = let
    perSystemCfg = getPerSystemCfg [
      (mkConfigModule {})
      (mkPluginsModule [
        {
          name = "sector7";
          version = "0.20.14";
        }
      ])
    ];
    shellHook = perSystemCfg.devShells.ci-pulumi.shellHook;
  in {
    expr =
      hasInfixAll [
        "nix-store"
        "--realise"
        "--add-root"
        "--indirect"
        "resource-sector7-v0.20.14"
      ]
      shellHook;
    expected = true;
  };

  # The gcroot symlink must live *outside* the versioned plugin directory
  # (as a `<dir>.gcroot` sibling), not inside it — Pulumi treats the
  # directory's own contents as the plugin's installed fingerprint, and an
  # extra file there is exactly the kind of thing that "unrecognized files
  # in plugin dir" style checks and `<dir>.partial` handling exist to guard
  # against.
  testPulumiPluginGcRootLivesOutsidePluginDir = let
    perSystemCfg = getPerSystemCfg [
      (mkConfigModule {})
      (mkPluginsModule [
        {
          name = "sector7";
          version = "0.20.14";
        }
      ])
    ];
    shellHook = perSystemCfg.jackpkgs.outputs.pulumiDevShell.shellHook;
  in {
    # Sibling form: "$_jackpkgs_plugin_dir.gcroot", not a file nested inside
    # "$_jackpkgs_plugin_dir/...".
    expr =
      lib.hasInfix ''"$_jackpkgs_plugin_dir.gcroot"'' shellHook
      && !(lib.hasInfix ''$_jackpkgs_plugin_dir/pulumi-resource-sector7.gcroot'' shellHook);
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
