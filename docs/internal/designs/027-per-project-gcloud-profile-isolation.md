# ADR 027: Per-Project gcloud Profile Isolation

## Status

Proposed

## Context

Multiple downstream repos (cavinsresearch/zeus, addendalabs/yard, jmmaloney4/garden)
use the jackpkgs `just auth` recipe to authenticate with GCP and Pulumi. Each repo
authenticates as a different GCP principal:

| Repo   | Account                  | IAM Org            | Pulumi Backend                  |
|--------|--------------------------|--------------------|---------------------------------|
| zeus   | jack@cavinsresearch.io   | cavinsresearch.io  | gs://cavins-pulumi-state        |
| yard   | jack@addendalabs.com     | addendalabs.com    | gs://addenda-pulumi-state       |
| garden | jmmaloney4@gmail.com     | *(none)*           | gs://jmmaloney4-pulumi-state    |

Today, `gcloud auth login --update-adc` writes Application Default Credentials (ADC)
to the global path `~/.config/gcloud/application_default_credentials.json`. Running
`just auth` in one project overwrites credentials used by another. Developers working
across multiple projects must re-authenticate several times per day when switching
contexts.

The `gcloud` CLI respects the `CLOUDSDK_CONFIG` environment variable, which redirects
**all** gcloud configuration and credential storage — including ADC, active account,
project, and cached tokens — to a specified directory. By setting `CLOUDSDK_CONFIG`
per-project in the Nix devshell, each project gets an isolated credential store that
coexists with others on the same machine.

### Relation to Existing ADRs

- **ADR 007** (GCP Account Configuration): Introduced `jackpkgs.gcp.iamOrg` and the
  `--account` flag on `gcloud auth login`. This ADR builds on that by isolating the
  credential store each login writes to.
- **ADR 009** (ADC Quota Project Configuration): Introduced `jackpkgs.gcp.quotaProject`.
  The quota project setting is written into the profile-local ADC, so it is also
  isolated per-project by this change.

## Decision

### 1. New option: `jackpkgs.gcp.profile`

Add a new option to the `jackpkgs.gcp` option set:

```nix
profile = lib.mkOption {
  type = lib.types.nullOr lib.types.str;
  default = cfg.gcp.iamOrg;
  description = ''
    Name of the gcloud profile directory under ~/.config/gcloud-profiles/.
    When set, CLOUDSDK_CONFIG is exported in the devshell to isolate gcloud
    credentials, ADC, and configuration per-project.

    Defaults to the value of jackpkgs.gcp.iamOrg when that option is set.
    Must be set explicitly when iamOrg is null and profile isolation is desired.
  '';
};
```

When `profile` is non-null, a profile directory at `~/.config/gcloud-profiles/<profile>/`
is used. When `profile` is null, behavior is unchanged (uses default `~/.config/gcloud/`).

### 2. Devshell environment: export `CLOUDSDK_CONFIG`

When `jackpkgs.gcp.profile` is non-null, the Pulumi devshell fragment
(`modules/flake-parts/pulumi.nix`) sets:

```nix
CLOUDSDK_CONFIG = "$HOME/.config/gcloud-profiles/${cfg.gcp.profile}";
```

The devshell shell hook ensures the directory exists:

```bash
mkdir -p "$CLOUDSDK_CONFIG"
```

Because direnv activates the devshell on `cd`, switching between project directories
automatically switches `CLOUDSDK_CONFIG`. No manual context-switch command is needed.

### 3. New recipe: `auth-status`

Add an `auth-status` recipe to the `infra` just-flake feature that displays the
current profile, authenticated account, project, and token validity:

```just
# Show current GCP authentication status
auth-status:
    #!/usr/bin/env bash
    echo "Profile:  ${CLOUDSDK_CONFIG:-~/.config/gcloud (default)}"
    echo "Account:  $(gcloud config get-value account 2>/dev/null || echo 'not set')"
    echo "Project:  $(gcloud config get-value project 2>/dev/null || echo 'not set')"
    if gcloud auth print-access-token --quiet >/dev/null 2>&1; then
        echo "Token:    valid"
    else
        echo "Token:    EXPIRED — run 'just auth'"
    fi
```

### 4. No changes to `auth` recipe logic

The existing `auth` recipe does not change. It already uses `gcloud auth login
--update-adc`, which respects `CLOUDSDK_CONFIG`. The isolation is achieved entirely
through the environment variable set by the devshell.

### 5. Downstream adoption

Each downstream repo adds one line to its `flake.nix`:

```nix
# zeus (iamOrg is already set, profile defaults to "cavinsresearch.io")
jackpkgs.gcp.iamOrg = "cavinsresearch.io";
# No explicit profile needed — defaults to iamOrg

# yard (iamOrg is already set, profile defaults to "addendalabs.com")
jackpkgs.gcp.iamOrg = "addendalabs.com";
# No explicit profile needed — defaults to iamOrg

# garden (no iamOrg — must set profile explicitly)
jackpkgs.gcp.profile = "jmmaloney4";
```

## Consequences

### Benefits

- **No re-authentication when switching projects.** Each project's credentials persist
  independently in `~/.config/gcloud-profiles/<profile>/`.
- **Automatic context switching.** direnv + `CLOUDSDK_CONFIG` means `cd`-ing into a
  project directory activates the correct GCP identity with no manual intervention.
- **Full credential isolation.** ADC, active account, cached tokens, and project config
  are all per-profile. No risk of deploying to the wrong org.
- **Zero-change for CI.** CI uses Workload Identity Federation, not gcloud profiles.
  `CLOUDSDK_CONFIG` is irrelevant in CI.
- **Backward compatible.** When `profile` is null (the default when `iamOrg` is also
  null), behavior is identical to today.

### Trade-offs

- Developers must run `just auth` once per profile after initial setup (or after token
  expiry). This is the same as today but scoped per-profile rather than global.
- Profile directories accumulate in `~/.config/gcloud-profiles/`. This is a minor
  disk-space concern; each profile is a few KB.

### Risks

- **Tool compatibility.** Any tool that reads ADC from the hardcoded default path
  (`~/.config/gcloud/application_default_credentials.json`) instead of respecting
  `CLOUDSDK_CONFIG` will not find credentials. Mitigation: `gcloud`, `pulumi`,
  `kubectl` (via `gke-gcloud-auth-plugin`), and `rclone` (with `env_auth = true`) all
  respect `CLOUDSDK_CONFIG`. If a tool does not, `GOOGLE_APPLICATION_CREDENTIALS` can
  be set as a fallback pointing to
  `$CLOUDSDK_CONFIG/application_default_credentials.json`.
- **Shared worktrees.** Multiple worktrees of the same repo share the same profile
  (by design). If different worktrees need different credentials, the developer must
  set `jackpkgs.gcp.profile` to distinct values. This is an unusual edge case.

## Alternatives Considered

### A: gcloud Named Configurations (`gcloud config configurations`)

Use gcloud's built-in named configurations with `gcloud config configurations create`
and `gcloud config configurations activate`.

**Pros:**
- Native gcloud feature; no custom env var management.

**Cons:**
- Named configurations isolate CLI account and project settings but **do not isolate
  ADC**. `application_default_credentials.json` is always global. Since ADC is what
  Pulumi, rclone, and other tools use, this does not solve the core problem.
- Requires explicit `activate` commands; does not integrate with direnv automatic
  switching.

**Why not:** Does not isolate ADC, which is the primary credential consumed by Pulumi
and other IaC tools.

### B: Per-Repo Local Config (`$repo_root/.gcloud/`)

Store gcloud config and credentials inside each repository's working directory.

**Pros:**
- Maximum isolation; credentials are truly per-checkout.

**Cons:**
- Must re-authenticate after every `git clone` or new worktree.
- Credentials in the repo directory risk accidental commits (even with `.gitignore`).
- Multiple worktrees of the same repo cannot share credentials.

**Why not:** Excessive friction for the common case. The `~/.config/gcloud-profiles/`
approach shares credentials across clones/worktrees of the same org, which matches
the real-world usage pattern.

### C: Manual `CLOUDSDK_CONFIG` in `.envrc.local`

Each developer manually adds `export CLOUDSDK_CONFIG=...` to their `.envrc.local`.

**Pros:**
- No jackpkgs changes needed.

**Cons:**
- Not reproducible; each developer must manually configure each repo.
- Easy to forget or misconfigure.
- Does not appear in `nix flake check` or any validation.

**Why not:** Violates the principle of reproducible, declarative developer environments
that jackpkgs exists to provide.

## Implementation Plan

1. Add `jackpkgs.gcp.profile` option in `modules/flake-parts/just.nix` (alongside
   existing `iamOrg` and `quotaProject` options).
2. Export `CLOUDSDK_CONFIG` in `modules/flake-parts/pulumi.nix` when `profile` is
   non-null, and add `mkdir -p` to the devshell shell hook.
3. Add `auth-status` recipe to the `infra` just-flake feature in
   `modules/flake-parts/just.nix`.
4. Add test cases in `tests/module-justfiles.nix` for profile-aware and
   profile-unaware auth generation.
5. Update downstream repos (zeus, yard, garden) to set `jackpkgs.gcp.profile` where
   needed (garden only, since zeus and yard default via `iamOrg`).

## Related

- [ADR 007: GCP Account Configuration](007-gcp-account-configuration.md)
- [ADR 009: ADC Quota Project Configuration](009-adc-quota-project-configuration.md)
- Impacted modules: `modules/flake-parts/just.nix`, `modules/flake-parts/pulumi.nix`
- Downstream repos: `cavinsresearch/zeus`, `addendalabs/yard`, `jmmaloney4/garden`

---

**Author:** jack
**Date:** 2026-02-18
