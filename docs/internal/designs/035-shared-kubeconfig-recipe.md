# ADR-035: Shared `just kubeconfig` Recipe

## Status

Proposed

## Context

- Three repos (garden, yard, zeus) each need `just kubeconfig` to configure kubectl for local use.
- Each has a hand-written recipe with different cluster auth mechanisms (mTLS certs via Pulumi TLS provider, `gcloud get-credentials`, decomposed config secrets).
- The zeus recipe was broken after a directory rename and has been deleted.
- Garden and yard each maintain their own recipe, diverging in mechanism and output path.
- All three repos use jackpkgs for Pulumi devshell and justfile generation (via `jackpkgs.pulumi` and `just-flake.features`).
- Garden already sets `$KUBECONFIG` to a repo-local path (`$REPO_ROOT/kubeconfig.yaml`) in its devshell. Yard writes to `~/.kube/config`.

## Decision

Add a `jackpkgs.kubeconfig` flake-parts module that:

1. Declares a `kubeconfig` stack output contract: every k8s Pulumi stack MUST export a `kubeconfig` output containing a complete kubeconfig YAML.
2. Generates a single `just kubeconfig` recipe that reads that output and writes to `$KUBECONFIG`.
3. Sets `$KUBECONFIG` to `$REPO_ROOT/kubeconfig.yaml` in the devshell when enabled.

The generated recipe is always:

```
pulumi -C <path> stack output kubeconfig --stack <stack> --show-secrets > "$KUBECONFIG"
```

What varies between repos is the Pulumi program that produces the kubeconfig (mTLS, GKE exec auth, config secret re-export). The consumer recipe is identical.

### Option: `jackpkgs.kubeconfig`

```nix
jackpkgs.kubeconfig = {
  enable = true;
  pulumiStackOutput = {
    path = "deploy/platform/k8s";
    stack = "prod";
  };
};
```

- `enable` (bool, default false): activates the kubeconfig recipe and `$KUBECONFIG` env var.
- `pulumiStackOutput.path` (str, required): Pulumi project directory relative to repo root.
- `pulumiStackOutput.stack` (str, default `"prod"`): stack name to query.

### Generated recipe

```just
# Write kubeconfig from Pulumi stack output to $KUBECONFIG
kubeconfig:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -z "${KUBECONFIG:-}" ]; then
      echo "KUBECONFIG not set — run from the nix devshell" >&2
      exit 1
    fi
    pulumi -C deploy/platform/k8s stack output kubeconfig --stack prod --show-secrets > "$KUBECONFIG"
    echo "kubeconfig written to $KUBECONFIG"
```

### `$KUBECONFIG` in devshells

When `jackpkgs.kubeconfig.enable` is true, the module exports:

```nix
KUBECONFIG = "$REPO_ROOT/kubeconfig.yaml"
```

using the same `flake-root` pattern as garden's existing devshell. This keeps per-repo clusters isolated from each other and from `~/.kube/config`.

`kubeconfig.yaml` should be in `.gitignore` per-repo.

## Consequences

### Benefits

- One recipe, one mechanism across all repos. The auth complexity stays inside the Pulumi program.
- New repos with k8s clusters get `just kubeconfig` by adding three lines to their `flake.nix`.
- Repo-local `$KUBECONFIG` prevents clobbering `~/.kube/config` when switching between repos.
- The contract is simple: if your Pulumi stack exports `kubeconfig`, you get the recipe.

### Trade-offs

- Yard must create a new Pulumi k8s platform stack that composes a GKE kubeconfig with the exec auth plugin. Currently yard calls `gcloud get-credentials` directly.
- Garden must remove its hand-written `$KUBECONFIG` export from `nix/devshell.nix` and hand-written `kubeconfig` recipe from its justfile.
- `$KUBECONFIG` shadowing: setting it in the devshell hides `~/.kube/config`. Users who rely on a global kubeconfig must run `just kubeconfig` in each repo. This is already garden's convention.

### Risks & Mitigations

- **Yard GKE kubeconfig correctness.** The composed kubeconfig with GKE exec auth plugin must match what `gcloud get-credentials` produces. Mitigation: test with `kubectl get nodes` before removing the old recipe.
- **Stack output must be a Pulumi secret.** The `kubeconfig` output contains auth material. The Pulumi program MUST wrap it with `pulumi.secret()` so `--show-secrets` is required to read it. Mitigation: document this as a hard requirement; add a check in the generated recipe.
- **Module placement.** This is a small module that integrates with both the devshell and just.nix features. It could live as a standalone module or as an extension to just.nix's infra feature. Mitigation: standalone module keeps concerns separated; the justfile content is wired into the infra feature via `config.jackpkgs.outputs.kubeconfigJustfile`.

## Alternatives Considered

### Alternative A — Extend just.nix infra feature inline

Add `jackpkgs.kubeconfig` options directly in just.nix alongside the existing pulumi options.

- Pros: fewer files, no new module registration.
- Cons: just.nix is already 616 lines. Adding kubeconfig options, recipe generation, and devshell env var logic would further bloat it. The kubeconfig concern is distinct from auth/preview/deploy.

### Alternative B — Per-repo hand-written recipes (status quo)

Keep each repo's hand-written recipe.

- Pros: no shared module to maintain.
- Cons: zeus recipe is already broken. Yard uses a different mechanism. Garden's recipe works but is not discoverable as a shared pattern. Every new repo duplicates the recipe.

## Implementation Plan

1. Create `modules/flake-parts/kubeconfig.nix` with options and config blocks.
2. Register in `all.nix` and `default.nix`.
3. Wire `kubeconfigJustfile` output into just.nix's infra feature (alongside `pulumiJustfile`).
4. Wire `$KUBECONFIG` env var via the devshell module's `inputsFrom` pattern.
5. Adopt in garden, zeus, yard (separate PRs per repo).

## Related

- Garden `justfile` lines 7-10: existing working kubeconfig recipe
- Garden `nix/devshell.nix` line 65: existing `$KUBECONFIG` export
- Yard `justfile` line 261: `gcloud get-credentials` recipe
- Zeus `deploy/platform/k8s/index.ts`: stores kubeconfig as config secret, re-exports as stack output
- ADR-034: Devshell Composition Contract (shell env hook pattern)

______________________________________________________________________

Author: Jack Maloney
Date: 2026-05-08
