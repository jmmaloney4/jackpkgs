# Plan: ADR 027 Per-Project gcloud Profile Isolation

**Status**: Proposed
**Date**: 2026-02-19
**ADR**: [027-per-project-gcloud-profile-isolation](../designs/027-per-project-gcloud-profile-isolation.md)

## Summary

Implement isolated gcloud configuration per-project by setting `CLOUDSDK_CONFIG` environment variable to a project-specific directory. This prevents credential conflicts when switching between projects.

## Task Breakdown

### 1. Add `profile` option to `modules/flake-parts/just.nix`

**Location**: After line 47 (after `quotaProject` option)

**Add option definition**:

```nix
profile = mkOption {
  type = types.nullOr types.str;
  default = cfg.gcp.iamOrg;
  defaultText = "config.jackpkgs.gcp.iamOrg";
  description = ''
    Name of the gcloud profile directory under ~/.config/gcloud-profiles/.
    When set, CLOUDSDK_CONFIG is exported in the devshell to isolate gcloud
    credentials, ADC, and configuration per-project.
    Defaults to the value of jackpkgs.gcp.iamOrg when that option is set.
  '';
};
```

**Acceptance Criteria**:

- [ ] Option compiles and is accessible via `config.jackpkgs.gcp.profile`
- [ ] Defaults to `iamOrg` when `iamOrg` is set
- [ ] Defaults to `null` when `iamOrg` is not set

______________________________________________________________________

### 2. Add `auth-status` recipe to `modules/flake-parts/just.nix`

**Location**: After line 204 (after `authRecipe` definition in infra feature)

**Add recipe definition**:

```nix
# auth-status recipe - shows current GCP authentication status
authStatusRecipe =
  mkRecipe "auth-status" "Show current GCP authentication status"
  [
    "#!/usr/bin/env bash"
    "echo \"Profile:  \${CLOUDSDK_CONFIG:-~/.config/gcloud (default)}\""
    "echo \"Account:  $(gcloud config get-value account 2>/dev/null || echo 'not set')\""
    "echo \"Project:  $(gcloud config get-value project 2>/dev/null || echo 'not set')\""
    "if gcloud auth print-access-token --quiet >/dev/null 2>&1; then"
    "    echo \"Token:    valid\""
    "else"
    "    echo \"Token:    EXPIRED — run 'just auth'\""
    "fi"
  ]
  true;
```

**Update justfile output logic**:

- Include `authStatusRecipe` in the infra justfile when `jackpkgs.gcp.profile != null`
- This recipe should be available whenever profile isolation is active (not gated on `pulumi.enable`)

**Acceptance Criteria**:

- [ ] Recipe generates valid justfile syntax
- [ ] Recipe is included when `profile` is set
- [ ] Recipe is not included when `profile` is `null`

______________________________________________________________________

### 3. Add `CLOUDSDK_CONFIG` environment variable to `modules/flake-parts/devshell.nix`

**Status**: Implemented in `devshell.nix` (supersedes original `pulumi.nix` plan)

**Location**: `modules/flake-parts/devshell.nix` `shellHook` for `jackpkgs.devshell.infra`

**Current code**:

```nix
env = {
  PULUMI_IGNORE_AMBIENT_PLUGINS = "1";
  PULUMI_BACKEND_URL = cfg.backendUrl;
  PULUMI_SECRETS_PROVIDER = cfg.secretsProvider;
};
```

**Replace with**:

```nix
env = let
  gcpCfg = config.jackpkgs.gcp;
in
  {
    PULUMI_IGNORE_AMBIENT_PLUGINS = "1";
    PULUMI_BACKEND_URL = cfg.backendUrl;
    PULUMI_SECRETS_PROVIDER = cfg.secretsProvider;
  }
  // lib.optionalAttrs (gcpCfg.profile != null) {
    CLOUDSDK_CONFIG = "$HOME/.config/gcloud-profiles/${gcpCfg.profile}";
  };
```

**Acceptance Criteria**:

- [ ] `CLOUDSDK_CONFIG` is set when `profile` is non-null
- [ ] `CLOUDSDK_CONFIG` is not set when `profile` is null
- [ ] Existing env vars remain unchanged

______________________________________________________________________

### 4. Ensure profile directory creation in `modules/flake-parts/devshell.nix`

**Status**: Implemented in `devshell.nix` (supersedes original `pulumi.nix` plan)

**Location**: `modules/flake-parts/devshell.nix` infra `shellHook`

**Add**:

```nix
shellHook = lib.optionalString (config.jackpkgs.gcp.profile != null) ''
  mkdir -p "$CLOUDSDK_CONFIG"
'';
```

**Acceptance Criteria**:

- [ ] Directory is created on shell entry when `profile` is set
- [ ] No action when `profile` is null
- [ ] Works with existing shellHooks (if any are added later, use `lib.concatStringsSep "\n"`)

______________________________________________________________________

### 5. Add test for `auth-status` recipe to `tests/module-justfiles.nix`

**Location**: After line 123 (after existing test definitions)

**Add test**:

```nix
# Test auth-status recipe pattern with CLOUDSDK_CONFIG variable
testAuthStatus = mkJustParseTest "auth-status" ''
  # Show current GCP authentication status
  auth-status:
      #!/usr/bin/env bash
      echo "Profile:  ''${CLOUDSDK_CONFIG:-~/.config/gcloud (default)}"
      echo "Account:  $(gcloud config get-value account 2>/dev/null || echo 'not set')"
      echo "Project:  $(gcloud config get-value project 2>/dev/null || echo 'not set')"
      if gcloud auth print-access-token --quiet >/dev/null 2>&1; then
          echo "Token:    valid"
      else
          echo "Token:    EXPIRED — run 'just auth'"
      fi
'';
```

**Add to test list**:

```nix
testAuthStatus
```

**Acceptance Criteria**:

- [ ] Test passes (`just --dump` parses successfully)
- [ ] Test runs in CI

______________________________________________________________________

## Files Changed Summary

| File                             | Change Type             |
| -------------------------------- | ----------------------- |
| `modules/flake-parts/just.nix`   | Add option + recipe     |
| `modules/flake-parts/pulumi.nix` | Add env var + shellHook |
| `tests/module-justfiles.nix`     | Add test                |

## Verification Steps

1. Run `nix flake check` to verify all options compile
2. Run tests: `nix build .#checks.x86_64-linux.module-justfiles`
3. Test in a downstream repo:
   ```nix
   jackpkgs.gcp.profile = "test-project";
   ```
4. Enter devshell and verify:
   ```bash
   echo $CLOUDSDK_CONFIG
   # Should output: /home/user/.config/gcloud-profiles/test-project

   just auth-status
   # Should show profile, account, project, token status

   ls ~/.config/gcloud-profiles/test-project
   # Directory should exist
   ```

## Rollback Plan

If issues arise:

1. Set `jackpkgs.gcp.profile = null;` in affected downstream repo
2. Revert changes to the three files
3. Delete any created `~/.config/gcloud-profiles/<profile>` directories

## Downstream Impact

| Repo   | Action Required                                            |
| ------ | ---------------------------------------------------------- |
| zeus   | None (profile defaults to iamOrg)                          |
| yard   | None (profile defaults to iamOrg)                          |
| garden | Set `jackpkgs.gcp.profile = "jmmaloney4";` (separate task) |
