# ADR-009: GCP ADC Quota Project Configuration

## Status

Accepted

## Context

When using Application Default Credentials (ADC) with GCP, API requests need to be billed against a specific project's quota. By default, gcloud attempts to infer the quota project from various sources (service account, user project, etc.), but this can be ambiguous or incorrect in multi-project environments.

The `gcloud auth application-default set-quota-project` command explicitly configures which GCP project's quota should be used for ADC-authenticated API calls. This is particularly important for:

- Projects using shared service accounts across multiple GCP projects
- Development environments where the user's default project differs from the project being developed
- Ensuring consistent quota/billing attribution

Currently, the `just auth` recipe (in `modules/flake-parts/just.nix`) runs `gcloud auth login --update-adc` but does not set a quota project, leaving it to gcloud's inference logic.

We need a way to:

1. Configure the quota project at the flake level (shared by all users on the project)
2. Automatically apply it during the `just auth` workflow
3. Maintain backward compatibility for projects that don't need this configuration

## Decision

Add a flake-level `jackpkgs.gcp.quotaProject` option for the GCP quota project ID.

When `quotaProject` is set, the `auth` recipe MUST:

- Call `gcloud auth application-default set-quota-project <quotaProject>` after the `auth login` step
- Execute this command unconditionally (no user-specific overrides needed)

When `quotaProject` is `null` (default), the recipe runs only `gcloud auth login`, preserving existing behavior.

### Implementation

**Option (flake-level):**

```nix
jackpkgs.gcp.quotaProject = mkOption {
  type = types.nullOr types.str;
  default = null;
  example = "my-project-123";
  description = ''
    GCP project ID to use for Application Default Credentials quota/billing.
    When set, the auth recipe will call:
      gcloud auth application-default set-quota-project <quotaProject>
  '';
};
```

**Recipe (auth command in infra feature):**

```bash
auth:
${lib.optionalString (cfg.gcp.iamOrg != null) ''
    : ''${GCP_ACCOUNT_USER:=$USER}
''}    ${lib.getExe sysCfg.googleCloudSdkPackage} auth login --update-adc${lib.optionalString (cfg.gcp.iamOrg != null) " --account=$GCP_ACCOUNT_USER@${cfg.gcp.iamOrg}"}
${lib.optionalString (cfg.gcp.quotaProject != null) ''
    ${lib.getExe sysCfg.googleCloudSdkPackage} auth application-default set-quota-project ${cfg.gcp.quotaProject}
''}
```

## Consequences

### Benefits

- Projects can enforce the correct quota project in their flake configuration
- Eliminates ambiguity about which project's quota is used for ADC
- No manual steps required after running `just auth`
- No breaking changes: existing flakes continue to work with `quotaProject = null`
- Consistent with ADR-007's pattern for GCP configuration options

### Trade-offs

- Adds another configuration option to the `jackpkgs.gcp` namespace
- Quota project is applied globally for ADC (not per-project if user works on multiple projects)
- No per-user customization (assumed unnecessary since quota project is project-specific)

### Risks & Mitigations

- **Risk:** User sets invalid project ID
  - **Mitigation:** gcloud will error with a clear message; user can fix flake config and re-run
- **Risk:** set-quota-project fails if user isn't authenticated
  - **Mitigation:** Command runs after `auth login`, ensuring user is authenticated first

## Alternatives Considered

### Alternative A — Environment Variable Only

- Use `GCP_QUOTA_PROJECT` env var, check in recipe
- Pros: No flake changes; users can override per-session
- Cons: Poor discoverability; not self-documenting; easy to forget
- Why not chosen: Flake configuration is more explicit and discoverable

### Alternative B — Separate Recipe

- Add `set-quota-project` as standalone recipe
- Pros: Flexibility to run independently
- Cons: Users might forget to run it; worse UX than automatic application
- Why not chosen: Automatic application during `auth` is more ergonomic

### Alternative C — Per-Environment Configuration

- Support map of environments to quota projects
- Pros: Handles multi-environment scenarios
- Cons: Adds complexity; unclear how to select environment; likely YAGNI
- Why not chosen: Single project is the common case; can extend later if needed

## Implementation Plan

1. Add `jackpkgs.gcp.quotaProject` option at the flake level in `modules/flake-parts/just.nix`
2. Update the `auth` recipe in the `infra` feature to conditionally call `set-quota-project`
3. Verify backward compatibility: test with `quotaProject = null` (existing behavior preserved)
4. Update `README.md` if `jackpkgs.gcp` options are documented in the user-facing docs

## Related

- Module: `modules/flake-parts/just.nix`
- Feature: `infra` (Pulumi/GCP authentication)
- ADR-007: GCP Account Configuration for Auth Recipe (established `jackpkgs.gcp` namespace pattern)

______________________________________________________________________

Author: jack\
Date: 2025-10-21\
PR: #<tbd>
