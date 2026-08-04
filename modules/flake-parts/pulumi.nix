{jackpkgsInputs}: {
  inputs,
  config,
  lib,
  ...
}: let
  inherit (lib) mkIf;
  cfg = config.jackpkgs.pulumi;
  gcpCfg = config.jackpkgs.gcp;

  justfileHelpers = import ../../lib/justfile-helpers.nix {inherit lib;};
  inherit (justfileHelpers) mkRecipe mkRecipeWithParams optionalLines;
in {
  options = let
    inherit (lib) types mkOption mkEnableOption;
    inherit (jackpkgsInputs.flake-parts.lib) mkDeferredModuleOption;
  in {
    jackpkgs.pulumi = {
      enable = mkEnableOption "jackpkgs-pulumi" // {default = true;};

      backendUrl = mkOption {
        type = types.str;
        description = "Pulumi backend URL to use for authentication and stack operations. Required when enable is true.";
      };

      secretsProvider = mkOption {
        type = types.str;
        description = "Pulumi secrets provider to use for authentication and stack operations. Required when enable is true.";
      };

      stacks = mkOption {
        type = types.listOf (types.submodule {
          options = {
            path = mkOption {
              type = types.str;
              description = "Path to the Pulumi project directory (relative to repo root).";
            };
            stacks = mkOption {
              type = types.listOf types.str;
              description = "Stack names available for this project (e.g. [\"dev\" \"stage\" \"prod\"]).";
            };
            alwaysDeploy = mkOption {
              type = types.bool;
              default = false;
              description = ''
                When true, this project is always deployed regardless of the selected
                environment stack. The effective stack is determined by matching the
                requested env against the project's stacks list; if no match is found,
                the first entry in stacks is used as a fallback.
              '';
            };
          };
        });
        default = [];
        description = "List of Pulumi projects and their available stacks, deployed in order.";
      };

      defaultStack = mkOption {
        type = types.str;
        default = "dev";
        description = "Default stack name used when not specified in preview/deploy commands.";
      };

      ci.authMode = mkOption {
        type = types.enum ["workload-identity" "application-default-credentials"];
        default = "workload-identity";
        description = ''
          Authentication mode for the ci-pulumi devShell.

          - `"workload-identity"` (default): rely on `GOOGLE_WORKLOAD_IDENTITY_PROVIDER`
            and `GOOGLE_SERVICE_ACCOUNT_EMAIL` injected by the CI runner (e.g. via
            google-github-actions/auth). `GOOGLE_APPLICATION_CREDENTIALS` is NOT set,
            so ADC falls through to ambient WIF credentials. Use this for GitHub
            Actions with Workload Identity Federation.

          - `"application-default-credentials"`: set `GOOGLE_APPLICATION_CREDENTIALS`
            to the per-profile ADC file under `$HOME/.config/gcloud-profiles/<profile>/`.
            Requires `jackpkgs.gcp.profile` to be non-null. Use this for self-hosted
            runners or local testing of the CI shell against a named gcloud profile.
        '';
      };
    };

    perSystem = mkDeferredModuleOption ({
      config,
      lib,
      options,
      pkgs,
      ...
    }: {
      options.jackpkgs.outputs.pulumiDevShell = mkOption {
        type = types.package;
        readOnly = true;
        description = "Pulumi devShell fragment to include in `inputsFrom`.";
      };

      options.jackpkgs.pulumi.plugins = mkOption {
        type = with types;
          listOf (submodule {
            options = {
              name = mkOption {
                type = str;
                description = "Plugin package name, e.g. \"sector7\".";
              };
              kind = mkOption {
                type = str;
                default = "resource";
                description = "Plugin kind. Pulumi supports resource, analyzer and converter.";
              };
              version = mkOption {
                type = str;
                description = "Plugin version WITHOUT a leading v, e.g. \"0.21.0\".";
              };
              package = mkOption {
                type = package;
                description = ''
                  Derivation providing bin/pulumi-<kind>-<name>. Must be a native
                  plugin binary; language-hosted plugins additionally need a
                  PulumiPlugin.yaml, which this hook does not write.
                '';
              };
            };
          });
        default = [];
        description = ''
          Pulumi plugins to link into $PULUMI_HOME/plugins for both the dev and
          CI shells, so local and CI resolve byte-identical binaries.

          Why linking rather than $PATH: pulumiBaseEnv sets
          PULUMI_IGNORE_AMBIENT_PLUGINS = "1" (asserted by checks.pulumi-ci-env)
          precisely so a stray pulumi-resource-* on PATH can never shadow a
          pinned plugin. Ambient resolution also ignores the version entirely,
          so a version-pinned SDK would silently bind to whatever binary came
          first. Populating the versioned plugin directory keeps that guarantee
          while still sourcing the binary from the Nix store.
        '';
      };

      options.jackpkgs.pulumi.ci.packages = mkOption {
        type = with types; listOf package;
        default = let
          isNodeEnabled =
            lib.hasAttrByPath ["jackpkgs" "outputs" "nodejsDevShell"] options
            && config.jackpkgs.outputs.nodejsDevShell != null;
          nodejsPackage =
            if isNodeEnabled
            then config.jackpkgs.nodejs.package
            else config.jackpkgs.pkgs.nodejs;
          pnpmPackages = lib.optional isNodeEnabled config.jackpkgs.nodejs.pnpmPackage;
        in
          with config.jackpkgs.pkgs;
            [
              pulumi-bin
              nodejsPackage
              jq
              (google-cloud-sdk.withExtraComponents [google-cloud-sdk.components.gke-gcloud-auth-plugin])
            ]
            ++ pnpmPackages;
        defaultText = lib.literalExpression ''
          with config.jackpkgs.pkgs; [
            pulumi-bin
            nodejs
            jq
            (google-cloud-sdk.withExtraComponents [google-cloud-sdk.components.gke-gcloud-auth-plugin])
          ] ++ lib.optional config.jackpkgs.nodejs.enable config.jackpkgs.nodejs.pnpmPackage
        '';
        description = ''
          Packages included in the ci-pulumi devshell. When the Node.js module
          is enabled, this includes its configured pnpm package so reusable
          Pulumi CI workflows can run `pnpm install` inside `.#ci-pulumi`.
        '';
      };

      options.jackpkgs.outputs.pulumiJustfile = mkOption {
        type = types.str;
        readOnly = true;
        description = "Generated justfile fragment for pulumi preview/deploy commands.";
      };
    });
  };

  config =
    mkIf cfg.enable
    {
      perSystem = {
        pkgs,
        lib,
        config,
        ...
      }: let
        pulumiExe = lib.getExe' pkgs.pulumi-bin "pulumi";
        mkShellEnvHook = import ../../lib/shell-env-hook.nix {inherit lib pkgs;};
        stacks = cfg.stacks;
        defaultStack = cfg.defaultStack;

        # Fail at evaluation time (not just in CI checks) when ADC authMode
        # is selected without a gcp.profile. Without this, the devShell would
        # silently skip GOOGLE_APPLICATION_CREDENTIALS.
        adcProfileRequired =
          cfg.ci.authMode
          == "application-default-credentials"
          && gcpCfg.profile == null;
        assertAdcProfile =
          lib.asserts.assertMsg (!adcProfileRequired)
          "jackpkgs.pulumi.ci.authMode 'application-default-credentials' requires jackpkgs.gcp.profile to be set";

        # Shared base env vars present in every Pulumi shell.
        pulumiBaseEnv = {
          PULUMI_IGNORE_AMBIENT_PLUGINS = "1";
          PULUMI_BACKEND_URL = cfg.backendUrl;
          PULUMI_SECRETS_PROVIDER = cfg.secretsProvider;
          PULUMI_OPTION_COLOR = "never";
          PULUMI_OPTION_SUPPRESS_PROGRESS = "true";
          # Enable async stack traces in Node.js for better debugging of unhandled
          # promise rejections (e.g. from @pulumi/pulumi). Without this, async stack
          # frames are absent from Error.stack, making unhandled rejections hard to trace.
          NODE_OPTIONS = "--async-context-frame";
        };

        # ADC file path for the active gcp.profile (null-safe: only used when profile != null).
        # Validate that profile is set when authMode requires it.
        # NOTE: This attrset is used only for the CI JSON env check (checks.pulumi-ci-env).
        # The actual GOOGLE_APPLICATION_CREDENTIALS export is done via shellHook
        # (adcShellHook) because the path contains $HOME which requires runtime expansion.
        profileAdcPath = lib.optionalAttrs (gcpCfg.profile != null) {
          GOOGLE_APPLICATION_CREDENTIALS = "$HOME/.config/gcloud-profiles/${gcpCfg.profile}/application_default_credentials.json";
        };

        ciPulumiEnv =
          pulumiBaseEnv
          // {PULUMI_OPTION_NON_INTERACTIVE = "true";}
          // lib.optionalAttrs (cfg.ci.authMode == "application-default-credentials") profileAdcPath;

        pulumiEnvHook = mkShellEnvHook {
          name = "jackpkgs-pulumi-env-hook";
          env = pulumiBaseEnv;
        };

        # CI needs NON_INTERACTIVE to prevent pulumi from prompting on stdin.
        # Local devshells intentionally omit it so interactive commands work.
        ciPulumiEnvHook = mkShellEnvHook {
          name = "jackpkgs-ci-pulumi-env-hook";
          env = pulumiBaseEnv // {PULUMI_OPTION_NON_INTERACTIVE = "true";};
        };

        # ADC path for the active gcp.profile. This uses $HOME expansion so it
        # cannot be carried by the setup hook (which single-quotes values).
        # Instead, export it via shellHook where shell expansion is available.
        adcShellHook = lib.optionalString (gcpCfg.profile != null) ''
          _jackpkgs_pulumi_adc_rel_path=${lib.escapeShellArg ".config/gcloud-profiles/${gcpCfg.profile}/application_default_credentials.json"}
          export GOOGLE_APPLICATION_CREDENTIALS="$HOME/$_jackpkgs_pulumi_adc_rel_path"
          unset _jackpkgs_pulumi_adc_rel_path
        '';
        # Links every declared plugin into $PULUMI_HOME/plugins/<kind>-<name>-v<ver>/.
        #
        # Layout verified against a natively-installed plugin: the versioned
        # directory contains the executable named pulumi-<kind>-<name>, and
        # nothing else is required. There is deliberately no PulumiPlugin.yaml —
        # that file is only for language-hosted plugins (nodejs/python/dotnet),
        # to tell the CLI which runtime to exec. Native binaries are exec'd
        # directly.
        #
        # `ln -sfn` makes this idempotent and self-healing: a version bump or a
        # store-path change relinks on the next shell entry. The `.partial`
        # marker is removed because Pulumi reads <dir>.partial as "install did
        # not finish" and will refuse the plugin. The `.lock` file is NOT
        # pre-created — Pulumi creates it itself and has write access.
        # Rendered into each shell's shellHook rather than a setup hook: setup
        # hooks are sourced during derivation *builds*, where HOME is
        # /homeless-shelter and unwritable, so linking there fails the build.
        # shellHook runs only on `nix develop` entry, which is when a plugin
        # directory is actually wanted.
        pluginLinkShellHook =
          lib.concatMapStringsSep "\n" (pl: ''
            _jackpkgs_plugin_dir="''${PULUMI_HOME:-$HOME/.pulumi}/plugins/${pl.kind}-${pl.name}-v${pl.version}"
            mkdir -p "$_jackpkgs_plugin_dir"
            ln -sfn ${lib.getExe' pl.package "pulumi-${pl.kind}-${pl.name}"} "$_jackpkgs_plugin_dir/pulumi-${pl.kind}-${pl.name}"
            rm -f "$_jackpkgs_plugin_dir.partial"
            unset _jackpkgs_plugin_dir
          '')
          config.jackpkgs.pulumi.plugins;
      in {
        jackpkgs.outputs.pulumiDevShell = pkgs.mkShell {
          packages =
            (with pkgs; [
              pulumi-bin
              nodejs
              jq
              just
              (google-cloud-sdk.withExtraComponents [google-cloud-sdk.components.gke-gcloud-auth-plugin])
              typescript
            ])
            ++ [pulumiEnvHook];
          # Literal env vars are carried by pulumiEnvHook (setup hook).
          # ADC path uses $HOME and must be set via shellHook for expansion.
          # Force ADC profile assertion to evaluate at shell build time.
          shellHook = builtins.seq assertAdcProfile (adcShellHook + pluginLinkShellHook);
        };

        devShells.ci-pulumi = pkgs.mkShell {
          packages = config.jackpkgs.pulumi.ci.packages ++ [ciPulumiEnvHook];

          # CI shell auth strategy is controlled by jackpkgs.pulumi.ci.authMode:
          #   "workload-identity" (default) — do not bake GOOGLE_APPLICATION_CREDENTIALS;
          #     WIF credentials are injected by the CI runner (google-github-actions/auth).
          #   "application-default-credentials" — set GOOGLE_APPLICATION_CREDENTIALS to
          #     the profile ADC file; requires jackpkgs.gcp.profile to be non-null.
          # Literal env vars are carried by ciPulumiEnvHook (setup hook).
          # ADC path (when enabled) uses $HOME and is set via shellHook.
          # Plugin linking matches the dev shell, so a plugin resolved locally
          # and one resolved on a self-hosted runner are the same store path.
          shellHook =
            lib.optionalString (cfg.ci.authMode == "application-default-credentials") adcShellHook
            + pluginLinkShellHook;
        };

        jackpkgs.shell.inputsFrom = [
          config.jackpkgs.outputs.pulumiDevShell
        ];

        # Verify that the ci-pulumi env block is well-formed and that authMode
        # controls GOOGLE_APPLICATION_CREDENTIALS as expected.
        checks.pulumi-ci-env = pkgs.runCommand "pulumi-ci-env-check" {} ''
          set -euo pipefail
          ciEnv=${lib.escapeShellArg (builtins.toJSON ciPulumiEnv)}
          echo "ci-pulumi env: $ciEnv"

          # PULUMI_IGNORE_AMBIENT_PLUGINS must always be present.
          echo $ciEnv | ${pkgs.jq}/bin/jq -e '.PULUMI_IGNORE_AMBIENT_PLUGINS == "1"' \
            || (echo "FAIL: PULUMI_IGNORE_AMBIENT_PLUGINS missing or wrong"; exit 1)

          authMode='${cfg.ci.authMode}'
          if [ "$authMode" = "workload-identity" ]; then
            # WIF mode: GOOGLE_APPLICATION_CREDENTIALS must NOT be set.
            echo $ciEnv | ${pkgs.jq}/bin/jq -e '.GOOGLE_APPLICATION_CREDENTIALS == null' \
              || (echo "FAIL: GOOGLE_APPLICATION_CREDENTIALS must not be set in workload-identity mode"; exit 1)
          else
            # ADC mode: GOOGLE_APPLICATION_CREDENTIALS must be present.
            echo $ciEnv | ${pkgs.jq}/bin/jq -e '.GOOGLE_APPLICATION_CREDENTIALS != null' \
              || (echo "FAIL: GOOGLE_APPLICATION_CREDENTIALS must be set in application-default-credentials mode"; exit 1)
          fi

          touch $out
        '';

        jackpkgs.outputs.pulumiJustfile = let
          hasStacks = stacks != [];
          projectCount = builtins.length stacks;

          allStackNames = lib.unique (lib.concatMap (s: s.stacks) stacks);
          displayStacks = lib.concatStringsSep ", " allStackNames;

          validationLogic =
            [
              "# Validate stack name"
              "valid_stacks=()"
            ]
            ++ map (stack: "valid_stacks+=(${lib.escapeShellArg stack})") allStackNames
            ++ [
              "is_valid=0"
              "for s in \"\${valid_stacks[@]}\"; do"
              "    if [[ \"\$s\" == \"\$env\" ]]; then"
              "        is_valid=1"
              "        break"
              "    fi"
              "done"
              "if [[ \$is_valid -eq 0 ]]; then"
              "    valid_stacks_display=${lib.escapeShellArg displayStacks}"
              "    printf '❌ Unknown stack: %s (valid: %s)\\n' \"\$env\" \"\$valid_stacks_display\""
              "    exit 1"
              "fi"
            ];

          previewRecipe =
            mkRecipeWithParams "preview" [''env="${defaultStack}"''] "Preview changes for all Pulumi projects (run 'just deploy' to apply)"
            ([
                "#!/usr/bin/env bash"
                "set -euo pipefail"
                # just does not pass recipe parameters as positional args to
                # shebang recipes (that needs `set positional-arguments`), so
                # $1 is always unset here and the old `env="${1:-default}"`
                # silently deployed the default stack no matter what the caller
                # asked for. Interpolate the parameter via just instead.
                "env={{quote(env)}}"
                "preview_summaries=()"
                "failed_previews=()"
                ""
                "# run_preview captures pulumi preview output, prints it in full, then"
                "# parses the 'Resources:' summary for create/replace/update/delete counts."
                "run_preview() {"
                "    local project_path=\"\$1\""
                "    local stack_name=\"\$2\""
                "    local preview_output normalized_output resources_summary create_count replace_count update_count delete_count preview_status"
                ""
                "    # Temporarily disable errexit so a failed preview still prints its output."
                "    set +e"
                "    preview_output=$(\"${pulumiExe}\" -C \"\$project_path\" preview --color never --stack \"\$stack_name\" 2>&1)"
                "    preview_status=\$?"
                "    set -e"
                "    printf '%s\\n' \"\$preview_output\""
                "    if [ \"\$preview_status\" -ne 0 ]; then"
                "        return \"\$preview_status\""
                "    fi"
                ""
                "    normalized_output=$(printf '%s\\n' \"\$preview_output\" | tr -d '\\r')"
                "    resources_summary=$(printf '%s\\n' \"\$normalized_output\" | sed -n '/^Resources:/,$p')"
                ""
                "    # Extract counts from the final Resources summary block."
                "    # Use [^0-9]* prefix (not .*) so multi-digit counts are captured fully."
                "    create_count=$(printf '%s\\n' \"\$resources_summary\" | sed -n 's/^[^0-9]*\\([0-9][0-9]*\\) to create.*/\\1/p' | tail -1)"
                "    replace_count=$(printf '%s\\n' \"\$resources_summary\" | sed -n 's/^[^0-9]*\\([0-9][0-9]*\\) to replace.*/\\1/p' | tail -1)"
                "    update_count=$(printf '%s\\n' \"\$resources_summary\" | sed -n 's/^[^0-9]*\\([0-9][0-9]*\\) to update.*/\\1/p' | tail -1)"
                "    delete_count=$(printf '%s\\n' \"\$resources_summary\" | sed -n 's/^[^0-9]*\\([0-9][0-9]*\\) to delete.*/\\1/p' | tail -1)"
                "    create_count=\${create_count:-0}"
                "    replace_count=\${replace_count:-0}"
                "    update_count=\${update_count:-0}"
                "    delete_count=\${delete_count:-0}"
                ""
                "    preview_summaries+=(\"\${project_path} (\${stack_name}) +\${create_count}/+-\${replace_count}/~\${update_count}/-\${delete_count}\")"
                "}"
                ""
              ]
              ++ validationLogic
              ++ [
                ""
                "echo \"🔍 Previewing all Pulumi projects for \$env stack...\""
                ""
              ]
              ++ lib.concatMap (s: let
                escapedPath = lib.escapeShellArg s.path;
                fallbackStack = lib.escapeShellArg (lib.head s.stacks);
                projectStackChecks = lib.concatStringsSep " || " (map (stack: "[[ \"\$env\" == ${lib.escapeShellArg stack} ]]") s.stacks);
              in
                if s.alwaysDeploy
                then [
                  "echo \"\""
                  "project_path=${escapedPath}"
                  "# Determine effective stack: use env if it matches, else fallback to ${lib.head s.stacks}"
                  "if ${projectStackChecks}; then"
                  "    _effective_stack=\"\$env\""
                  "else"
                  "    _effective_stack=${fallbackStack}"
                  "fi"
                  "printf '📦 Previewing %s (stack: %s, alwaysDeploy)...\\n' \"\$project_path\" \"\$_effective_stack\""
                  "if ! run_preview \"\$project_path\" \"\$_effective_stack\"; then"
                  "    failed_previews+=(\"\$project_path (\$_effective_stack)\")"
                  "fi"
                ]
                else [
                  "echo \"\""
                  "project_path=${escapedPath}"
                  "if ${projectStackChecks}; then"
                  "    printf '📦 Previewing %s (stack: %s)...\\n' \"\$project_path\" \"\$env\""
                  "    if ! run_preview \"\$project_path\" \"\$env\"; then"
                  "        failed_previews+=(\"\$project_path (\$env)\")"
                  "    fi"
                  "else"
                  "    printf '⏭️  Skipping %s (stack %s not configured for this project)\\n' \"\$project_path\" \"\$env\""
                  "fi"
                ])
              stacks
              ++ [
                ""
                "echo \"\""
                "echo \"📊 Preview summary:\""
                "for summary in \"\${preview_summaries[@]}\"; do"
                "    printf '%s\\n' \"\$summary\""
                "done"
                "echo \"\""
                "if [ \${#failed_previews[@]} -eq 0 ]; then"
                "    echo \"✅ Preview complete! Run 'just deploy' to apply changes.\""
                "    exit 0"
                "else"
                "    echo \"⚠️  Preview completed with failures\""
                "    echo \"\""
                "    echo \"❌ Failed previews:\""
                "    for stack in \"\${failed_previews[@]}\"; do"
                "        echo \"   - \$stack\""
                "    done"
                "    exit 1"
                "fi"
              ])
            false;

          deployRecipe =
            mkRecipeWithParams "deploy" [''env="${defaultStack}"''] "Deploy all Pulumi projects in dependency order"
            ([
                "#!/usr/bin/env bash"
                "set -euo pipefail"
                # See previewRecipe: $1 is never set in shebang recipes, so the
                # parameter must be interpolated by just.
                "env={{quote(env)}}"
                ""
              ]
              ++ validationLogic
              ++ [
                ""
                "set +e"
                ""
                "echo \"🚀 Deploying all Pulumi projects for \$env stack...\""
                "echo \"\""
                ""
                "failed_stacks=()"
                ""
              ]
              ++ lib.concatLists (lib.imap0 (i: s: let
                stepNum = i + 1;
                escapedPath = lib.escapeShellArg s.path;
                fallbackStack = lib.escapeShellArg (lib.head s.stacks);
                projectStackChecks = lib.concatStringsSep " || " (map (stack: "[[ \"\$env\" == ${lib.escapeShellArg stack} ]]") s.stacks);
              in
                if s.alwaysDeploy
                then [
                  "project_path=${escapedPath}"
                  "# Determine effective stack: use env if it matches, else fallback to ${lib.head s.stacks}"
                  "if ${projectStackChecks}; then"
                  "    _effective_stack=\"\$env\""
                  "else"
                  "    _effective_stack=${fallbackStack}"
                  "fi"
                  "printf '📦 Step ${toString stepNum}/${toString projectCount}: Deploying %s (stack: %s, alwaysDeploy)...\\n' \"\$project_path\" \"\$_effective_stack\""
                  "if ! ${pulumiExe} -C \"\$project_path\" up --yes --stack \"\$_effective_stack\"; then"
                  "    failed_stacks+=(\"\$project_path (\$_effective_stack)\")"
                  "fi"
                  "echo \"\""
                  ""
                ]
                else [
                  "project_path=${escapedPath}"
                  "if ${projectStackChecks}; then"
                  "    printf '📦 Step ${toString stepNum}/${toString projectCount}: Deploying %s...\\n' \"\$project_path\""
                  "    if ! ${pulumiExe} -C \"\$project_path\" up --yes --stack \"\$env\"; then"
                  "        failed_stacks+=(\"\$project_path (\$env)\")"
                  "    fi"
                  "else"
                  "    printf '⏭️  Step ${toString stepNum}/${toString projectCount}: Skipping %s (stack %s not configured for this project)\\n' \"\$project_path\" \"\$env\""
                  "fi"
                  "echo \"\""
                  ""
                ])
              stacks)
              ++ [
                "# Report summary"
                "if [ \${#failed_stacks[@]} -eq 0 ]; then"
                "    echo \"✅ All projects deployed successfully!\""
                "    exit 0"
                "else"
                "    echo \"⚠️  Deployment completed with failures\""
                "    echo \"\""
                "    echo \"❌ Failed projects:\""
                "    for stack in \"\${failed_stacks[@]}\"; do"
                "        echo \"   - \$stack\""
                "    done"
                "    exit 1"
                "fi"
              ])
            false;
        in
          if hasStacks
          then lib.concatStringsSep "\n\n" [previewRecipe deployRecipe]
          else "";
      };
    };
}
