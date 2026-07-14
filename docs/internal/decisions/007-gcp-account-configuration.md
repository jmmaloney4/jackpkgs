# ADR-007: GCP Account Configuration for Auth Recipe

## Status

Proposed

## Context

The `just auth` recipe (in `modules/flake-parts/just.nix`) authenticates with GCP via `gcloud auth login --update-adc`. Currently, it does not specify an account, leaving users to select from their configured accounts interactively or use whichever account is currently default.

For team projects:

- The GCP IAM organization domain is constant across all users (e.g., `example.com`)
- Individual usernames vary by developer (e.g., `alice`, `bob`, `charlie`)
- The full account format is `username@organization.com`

We need a way to:

1. Configure the IAM organization at the flake level (shared by all users)
2. Allow each user to specify their username (defaulting to their Unix username)
3. Pass the constructed account to `gcloud auth login --account`

## Decision

Add a flake-level `jackpkgs.gcp.iamOrg` option for the GCP IAM organization domain.

When `iamOrg` is set, the `auth` recipe MUST:

- Construct the account as `${GCP_ACCOUNT_USER}@${iamOrg}`
- Default `GCP_ACCOUNT_USER` to the current Unix username (`$USER`)
- Allow users to override via the `GCP_ACCOUNT_USER` environment variable
- Pass the constructed account to `gcloud auth login --account`

When `iamOrg` is `null` (default), the recipe runs `gcloud auth login` without `--account`, preserving existing behavior.

### Implementation

**Option (flake-level):**

```nix
jackpkgs.gcp = {
  iamOrg = mkOption {
    type = types.nullOr types.str;
    default = null;
    example = "example.com";
    description = ''
      GCP IAM organization domain for constructing user accounts.
      When set, the auth recipe will use --account=$GCP_ACCOUNT_USER@$IAM_ORG
      where GCP_ACCOUNT_USER defaults to the current Unix username.
    '';
  };
};
```

**Recipe (auth command in infra feature):**

When `iamOrg` is set, the recipe uses a bash script with shebang to ensure all commands run in the same shell:

```bash
auth:
    #!/usr/bin/env bash
    GCP_ACCOUNT_USER="''${GCP_ACCOUNT_USER:-$USER}"
    ${lib.getExe sysCfg.googleCloudSdkPackage} auth login --update-adc --account=$GCP_ACCOUNT_USER@${cfg.gcp.iamOrg}
```

When `iamOrg` is null, the recipe is simpler (no variable assignment needed):

```bash
auth:
    ${lib.getExe sysCfg.googleCloudSdkPackage} auth login --update-adc
```

**Implementation notes:**

- The shebang (`#!/usr/bin/env bash`) ensures all recipe lines run in the same shell, so the variable assignment persists
- We use `${VAR:-default}` syntax which provides a default when the variable is unset or empty
- Without the shebang, each line would run in a separate shell, causing the variable to be lost

## Consequences

### Benefits

- Projects can enforce the correct IAM organization in their flake configuration
- Users get sensible defaults (their Unix username) without manual configuration
- Users can override when their GCP username differs from their Unix username
- No breaking changes: existing flakes continue to work with `iamOrg = null`

### Trade-offs

- Adds another configuration option to the `jackpkgs.gcp` namespace
- Requires users to understand the relationship between Unix username and GCP account

### Risks & Mitigations

- **Risk:** User's Unix username doesn't match their GCP username prefix
  - **Mitigation:** `GCP_ACCOUNT_USER` environment variable allows override
- **Risk:** User needs to authenticate with multiple organizations
  - **Mitigation:** They can set `GCP_ACCOUNT_USER=user@other-org.com` (full email override) or run `gcloud auth login` directly

## Alternatives Considered

### Alternative A — Full Account Override via `GCP_ACCOUNT`

- Use `GCP_ACCOUNT` for the complete email instead of just the username part
- Pros: Maximum flexibility; users can override organization too
- Cons: Defeats the purpose of having flake-level organization config; error-prone (users might typo the domain)
- Why not chosen: The organization is project-specific and shouldn't vary per-user

### Alternative B — Per-User Config File

- Let users configure their GCP username in `~/.config/jackpkgs/gcp.conf`
- Pros: Persistent configuration; no env vars needed
- Cons: Extra file to maintain; unclear discovery; adds I/O to recipe execution
- Why not chosen: Environment variable is simpler and more standard in dev tooling

### Alternative C — No Default, Require Explicit Configuration

- Don't default to `$USER`; require users to always set `GCP_ACCOUNT_USER`
- Pros: Explicit is better than implicit
- Cons: Poor UX for the common case where Unix username matches GCP username
- Why not chosen: Defaults improve ergonomics without sacrificing override capability

## Implementation Plan

1. Add `jackpkgs.gcp.iamOrg` option at the flake level in `modules/flake-parts/just.nix`
2. Update the `auth` recipe in the `infra` feature to conditionally construct and pass `--account`
3. Update `README.md` if the `gcp` options namespace is new and user-facing
4. Test with `iamOrg = null` (existing behavior) and with `iamOrg = "example.com"` (new behavior)

## Related

- Module: `modules/flake-parts/just.nix`
- Feature: `infra` (Pulumi/GCP authentication)
- ADR-001: Justfile Recipe Construction Utilities (may apply if recipe helpers are used)

______________________________________________________________________

Author: jack\
Date: 2025-10-21\
PR: #<tbd>
