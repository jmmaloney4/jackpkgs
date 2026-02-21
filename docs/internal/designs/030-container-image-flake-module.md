# ADR-030: Container Image flake-parts Module

## Status

Proposed

## Context

Two consumer repositories of jackpkgs — `addendalabs/yard` and `cavinsresearch/zeus` — both build
Linux container images using [nix2container](https://github.com/nlewo/nix2container) and push them
to container registries as part of their deployment workflows. Both repos arrived at nearly
identical patterns independently, but with divergent naming conventions, layering strategies,
just recipe names, and registry auth approaches.

### Current State in yard

- `nix2container` is a direct flake input added per-repo; not threaded through jackpkgs.
- Images are defined in `nix/images/default.nix` as a plain Nix function, imported manually into
  `perSystem` packages.
- Images land at `packages.x86_64-linux.<name>-image` — system is hardcoded in recipe invocations.
- A shared `commonEnv` (`buildEnv` of bash, cacert, coreutils, iana-etc, python) is collapsed into
  a single shared layer; a `busyboxLayer` adds `/bin/sh` for Cloud Run.
- A `mkToolImage` helper abstracts per-tool image definitions.
- Just recipes: `image-digest TOOL`, `image-push-one TOOL TAG REGISTRY`,
  `image-push-all TAG REGISTRY`.
- Auth: `gcloud auth print-access-token` + `oauth2accesstoken` scheme for GCP Artifact Registry.
- Push mechanism: `nix run github:nlewo/nix2container#skopeo-nix2container -- copy` invoked
  directly in just recipe shell.

### Current State in zeus

- `nix2container` is a direct flake input added per-repo.
- Images are defined in a flake-parts `perSystem` module at `nix/images/default.nix`.
- Images land at `packages.${system}.<name>-image` — system is NOT restricted to Linux, so darwin
  builds are technically attempted (though useless).
- Per-image layering: each dep package gets its own `buildLayer { copyToRoot = drv; }` plus a
  final `buildLayer { deps = layerInputs; }` for transitive closure. No `layers` deduplication
  param is passed between layers (a known efficiency gap).
- An `entrypoint-wrapper` script handles runtime env setup (Redis CA cert merging) before `exec`.
- Just recipe: `push-image name` — but recipe body hardcodes `zeus-image` instead of
  `{{name}}-image` (known bug).
- Auth: 1Password `op read` for GHCR username/password.
- Push mechanism: `nix2container`'s native `passthru.copyTo` (the image's own copy derivation).

### Problems to Solve

1. **No standardized output namespace.** Images buried in `packages.${system}.*` with `-image`
   suffix makes them hard to discover and requires consumers to know the system string.
2. **No platform gating.** Images should only exist on Linux; darwin builds are wasted effort.
3. **nix2container is re-declared per-repo.** Consumers must add and pin the input themselves.
4. **Inconsistent just recipe names.** `image-push-one` / `push-image` / `image-digest` — no
   single convention across repos.
5. **Layer deduplication is incomplete.** The naive per-`buildLayer` approach repeats shared store
   paths (e.g., glibc, libc) across layers unless the `layers` exclusion parameter is threaded
   through correctly.
6. **Auth is hardcoded to each repo's registry.** No opinionated but configurable auth abstraction.

______________________________________________________________________

## Decision

We will add a `container` flake-parts module to jackpkgs (`modules/flake-parts/container.nix`)
that standardizes container image definition, platform gating, layer strategy, flake output
structure, and just recipes across all consumer repos.

### Output structure: `outputs.images.<name>`

Images MUST be exposed as a top-level flake output `outputs.images.<name>` rather than under
`packages.${system}.*`. Each value is a nix2container image derivation built for `x86_64-linux`.

```
outputs.images.klotho     # nix2container image, always x86_64-linux
outputs.images.poseidon
outputs.images.ingest
```

This output is not `perSystem` — it is a single attribute set at the flake level, with the Linux
system baked in. Users build with:

```sh
nix build .#images.klotho
```

This produces a `result` symlink to a JSON manifest (the nix2container local format), which can
then be pushed with `skopeo-nix2container copy nix:./result docker://...`.

The dedicated `images` namespace was chosen over `packages.${system}.*` because:

- Images are platform-specific by nature; including them in the per-system `packages` attrset
  creates false symmetry (they should not appear on darwin at all).
- `nix build .#images.klotho` works without specifying a system string because `images` is a
  flat attrset — Nix does not need to disambiguate by system.
- Discovery is immediate: `nix flake show` reveals all images in one place.

### Platform gating: x86_64-linux only (for now)

All image derivations MUST be built for `x86_64-linux`. The module MUST NOT define images for
darwin systems. Consumers on darwin machines that have a linux builder configured in
`~/.config/nix/nix.conf` (or `/etc/nix/nix.conf`) will transparently offload the build to that
builder, producing a linux image. This is the expected workflow for the jackpkgs author whose
darwin machines all have a linux builder via nixbuild.net.

Multiarch support (x86_64-linux + aarch64-linux OCI manifest lists) is a future enhancement; see
Appendix A.

### nix2container as a jackpkgs input

`nix2container` MUST be added as an input to jackpkgs itself and threaded into the container
module via `jackpkgsInputs`. Consumer repos MUST NOT need to add `nix2container` as their own
flake input. Consumers MAY override by passing their own `nix2containerInput` option if they need
a specific pin.

### Layer strategy: hybrid common + per-image

The module uses a two-tier layer strategy combining the best aspects of both repos:

**Tier 1 — Common layer** (optional, shared across all images):

A `commonPackages` option accepts a list of packages that are combined into a single `buildEnv`
and emitted as one shared layer. This layer appears in every image defined by the module and is
only stored once in the registry. Typical contents: `bashInteractive`, `cacert`, `coreutils`,
`iana-etc`, plus any shared runtime (e.g., a Python environment).

```nix
jackpkgs.images.commonPackages = with pkgs; [
  bashInteractive cacert coreutils iana-etc myPython
];
```

**Tier 2 — Per-image layers** (optional, image-specific packages):

Each image may declare additional `packages` that are layered using the
`foldImageLayers`/exclusion-chain pattern to eliminate duplicate store paths.

#### Layer deduplication

This is the key correctness issue discovered during the yard and zeus implementations. When
multiple `buildLayer` calls are made for different packages, nix2container includes the full
transitive closure of each package in its layer. Because many packages share deep dependencies
(glibc, openssl, etc.), naive layering repeats those store paths across every layer, wasting
registry space and push bandwidth.

The fix is to pass all previously-built layers to each subsequent `buildLayer` call via the
`layers` parameter. nix2container will then skip any store path that already appears in a prior
layer:

```nix
# WRONG — glibc duplicated in every layer
layers = map (drv: buildLayer { copyToRoot = drv; }) [pkgA pkgB pkgC];

# CORRECT — each layer excludes what came before
commonLayer = buildLayer { copyToRoot = commonEnv; };
pkgALayer   = buildLayer { copyToRoot = pkgA; layers = [commonLayer]; };
pkgBLayer   = buildLayer { copyToRoot = pkgB; layers = [commonLayer pkgALayer]; };
pkgCLayer   = buildLayer { copyToRoot = pkgC; layers = [commonLayer pkgALayer pkgBLayer]; };
```

The module implements this with a `foldl` accumulator (equivalent to the `foldImageLayers`
pattern from https://blog.eigenvalue.net/2023-nix2container-everything-once/):

```nix
foldImageLayers = nix2container: baseLayers: pkgList:
  let
    fold = acc: drv:
      let layer = nix2container.buildLayer {
            copyToRoot = drv;
            layers = acc;   # exclude everything already in prior layers
          };
      in acc ++ [layer];
  in lib.foldl fold baseLayers pkgList;
```

The common layer (tier 1) is passed as the initial `baseLayers`, so per-image layers
automatically exclude all common store paths.

### Module options

```nix
# Top-level (flake-wide)
jackpkgs.images.enable          # bool, default false
jackpkgs.images.linuxSystem     # str, default "x86_64-linux"
jackpkgs.images.registry        # str | null, default null
                                # e.g. "ghcr.io/myorg/myrepo"
                                # per-image registry overrides this

# Per-system (evaluated on the consumer's perSystem)
# These options live under perSystem so pkgs is available for package references
jackpkgs.images.commonPackages  # listOf package, default []
                                # packages placed in the shared common layer

jackpkgs.images.images          # attrsOf imageSubmodule
  # imageSubmodule options:
  #   name        str (inferred from attrset key; overridable)
  #   packages    listOf package, default []  — per-image layer packages
  #   entrypoint  listOf str                  — OCI entrypoint
  #   cmd         listOf str, default []      — OCI cmd
  #   env         listOf str, default []      — OCI env vars (KEY=val)
  #               SSL_CERT_FILE is injected automatically
  #   workingDir  str, default "/workspace"
  #   tag         str, default "latest"
  #   registry    str | null, default null    — overrides jackpkgs.images.registry
  #   extraLayers listOf buildLayer result    — escape hatch for raw nix2container layers
```

### Authentication strategy

Both registries in use (GCP Artifact Registry, GHCR) need credentials at push time. The push
mechanism is `skopeo-nix2container copy --dest-creds`. The module provides a configurable
`image-push` just recipe with a `CREDS` parameter that accepts the credential string directly,
plus two named modes that derive credentials automatically:

**Mode A — `ghcr` (recommended for GHCR):** Uses `GITHUB_TOKEN` env var (already present in
devshells and CI via the existing jackpkgs GitHub module).

```sh
--dest-creds "${GITHUB_ACTOR}:${GITHUB_TOKEN}"
```

**Mode B — `gcp` (recommended for GCP Artifact Registry):** Uses `gcloud auth print-access-token`.

```sh
--dest-creds "oauth2accesstoken:$(gcloud auth print-access-token)"
```

**Mode C — `op` (1Password):** Reads username/password from 1Password vault references.

```sh
--dest-creds "$(op read op://vault/item/username):$(op read op://vault/item/password)"
```

**Mode D — `raw` (escape hatch):** Consumer provides the full `--dest-creds` value as a just
argument.

The module exposes a `jackpkgs.images.authMode` option (`"ghcr"` | `"gcp"` | `"op"` | `"raw"`,
default `"ghcr"`) and mode-specific suboptions:

```nix
jackpkgs.images.authMode = "ghcr";  # default

# for "op" mode:
jackpkgs.images.auth.op.usernameRef = "op://vault/item/username";
jackpkgs.images.auth.op.passwordRef = "op://vault/item/password";

# for "raw" mode: consumer passes CREDS=... at just invocation time
```

The `"ghcr"` default is chosen because GHCR is the lowest-friction option for the jackpkgs
ecosystem (no extra tooling; `GITHUB_TOKEN` is already present in the devshell from the GitHub
workflow integrations).

### Just recipes

The module contributes the following recipes to `just-flake.features.images`:

```just
# Build a container image locally (produces ./result JSON manifest)
image-build name:
    nix build .#images.{{name}}

# Show the SHA256 digest of a locally-built image
image-digest name: (image-build name)
    nix run github:nlewo/nix2container#skopeo-nix2container -- \
        inspect nix:./result | jq -r '.Digest'

# Push a single image to its configured registry
# TAG defaults to "latest"; CREDS is only used in "raw" auth mode
image-push name tag="latest":
    #!/usr/bin/env bash
    set -euo pipefail
    nix build .#images.{{name}}
    DEST="<registry>/{{name}}:{{tag}}"
    CREDS="<derived from authMode>"
    nix run github:nlewo/nix2container#skopeo-nix2container -- \
        copy --dest-creds "${CREDS}" nix:./result "docker://${DEST}"

# Push all images defined in jackpkgs.images.images
image-push-all tag="latest":
    #!/usr/bin/env bash
    set -euo pipefail
    for name in <image names from module config>; do
        just image-push "${name}" {{tag}}
    done
```

Recipe names use the `image-*` prefix (matching yard's convention, which is more explicit than
zeus's `push-image` name, and consistent with the `image-build` / `image-digest` pair).

______________________________________________________________________

## Consequences

### Benefits

- Consumer repos add one flake module import and declare images in Nix; they get correct layering,
  platform gating, a clean `outputs.images.*` namespace, and standardized just recipes for free.
- `nix2container` is pinned once in jackpkgs; consumers don't manage the input.
- Layer deduplication is handled correctly by the module so consumers cannot accidentally create
  bloated images.
- `nix build .#images.klotho` works from darwin transparently (builds on linux builder).
- Unified just recipe naming across yard and zeus eliminates tribal knowledge.
- Switching registry or auth mode is a single option change, not a justfile rewrite.

### Trade-offs

- Images are pinned to `x86_64-linux` only for now. Multiarch requires future work (Appendix A).
- The `outputs.images` top-level output is not a standard Nix flake output type; `nix flake check`
  will not validate it automatically and tooling that only inspects `packages.*` will not see it.
- Consumers that need highly custom layering (e.g., yard's static busybox `/bin/sh` layer for
  Cloud Run) must use the `extraLayers` escape hatch, which reintroduces direct nix2container API
  usage.

### Risks & Mitigations

- **Risk:** nix2container API changes break the module.
  **Mitigation:** Pin `nix2container` input in jackpkgs. Provide a `nix2containerInput` override
  option so consumers can temporarily pin to a different version.

- **Risk:** `foldImageLayers` deduplication produces surprising results if a package is in both
  `commonPackages` and a per-image `packages` list.
  **Mitigation:** The module SHOULD emit a warning (or assertion) if the same derivation appears
  in both lists.

- **Risk:** `outputs.images.*` is not evaluated lazily by all Nix CLI versions; evaluating images
  on the wrong system could fail.
  **Mitigation:** Wrap image derivations in `builtins.seq (assert currentSystem == linuxSystem)`
  or use `pkgs.lib.systems.elaborate` to guard evaluation.

______________________________________________________________________

## Alternatives Considered

### Alternative A — Keep images in `packages.${system}.*`

Continue burying images in `packages.${system}.<name>-image` with `filterByPlatforms` to hide
them on darwin.

- Pros: Works with standard `nix build .#<name>-image`; no new output namespace.
- Cons: Platform filtering still evaluates on darwin; `-image` suffix is a naming wart; darwin
  users see confusing absence rather than a clear "linux-only" signal; harder to list all images.
- Why not chosen: The dedicated `images` namespace is cleaner, more intentional, and matches the
  user's stated preference (Q6).

### Alternative B — Use `dockerTools.buildLayeredImage` (nixpkgs built-in)

Use nixpkgs's built-in `dockerTools` instead of nix2container.

- Pros: No additional input; widely documented; `nix build` produces a `.tar.gz` directly loadable
  by Docker.
- Cons: Layer count is heuristic (`maxLayers`), not fully controllable; no deduplication across
  images; `streamLayeredImage` doesn't produce a stable content-addressed result; push requires
  loading into Docker daemon first (`docker load`) then `docker push`, adding a heavyweight
  daemon dependency to CI.
- Why not chosen: yard and zeus both evaluated this and chose nix2container for its superior
  daemon-free push (skopeo), deterministic layers, and cross-image layer sharing. That evaluation
  stands.

### Alternative C — One recipe per image (no `image-push-all`)

Generate one `image-push-<name>` recipe per image instead of a parameterized `image-push name`.

- Pros: More discoverable via `just --list`; no need to know image names up front.
- Cons: Recipe list grows with image count; just doesn't support dynamic recipe generation from
  Nix attrsets elegantly; parameterized `image-push name` is consistent with `just --list` showing
  the parameter.
- Why not chosen: The `image-push name` pattern (with tab-completion) is flexible without
  cluttering `just --list`; `image-push-all` covers the "push everything" case.

### Alternative D — `passthru.copyTo` as the push mechanism

Use nix2container's `passthru.copyTo` (zeus's approach) rather than explicitly invoking
`skopeo-nix2container copy` in the just recipe.

- Pros: Push is a first-class Nix derivation; `nix run .#images.klotho.passthru.copyTo` works
  without just.
- Cons: Registry URL must be baked into the derivation at eval time; changing tag or target
  requires a re-eval; `--dest-creds` cannot be passed at runtime; CI needs `nix run` not `just`.
- Why not chosen: The `skopeo-nix2container copy` approach in just recipes is more flexible —
  the registry and tag are runtime parameters, not eval-time constants. This matches yard's
  working pattern and is necessary for tag-per-git-sha workflows (Pulumi, CI).

______________________________________________________________________

## Implementation Plan

1. **Add `nix2container` input to jackpkgs `flake.nix`.**
   Pin to a recent stable commit. Wire through `jackpkgsInputs` to the new module.

2. **Create `modules/flake-parts/container.nix`.**

   - Define `jackpkgs.images.*` options (top-level and perSystem).
   - Implement `foldImageLayers` helper inline (or in `lib/container-helpers.nix`).
   - Wire `config.flake.images` output using `pkgsFor.x86_64-linux` (or the `linuxSystem` option).
   - Emit the `just-flake.features.images` feature.

3. **Register in `all.nix` and `default.nix`.**
   Add `container.nix` to the `imports` list in `all.nix` and expose
   `flakeModules.container` in `default.nix`.

4. **Migrate yard.**
   Replace `nix/images/default.nix` + manual flake-module wiring with:

   ```nix
   jackpkgs.images = {
     registry = "us-east1-docker.pkg.dev/addenda-admin/addenda";
     authMode = "gcp";
     commonPackages = with pkgs; [bashInteractive cacert coreutils iana-etc yardPython];
     images = {
       ingest        = { entrypoint = ["${yardPython}/bin/ingest"];         };
       text-extract  = { entrypoint = ["${yardPython}/bin/text-extract"];   };
       standardizer  = { entrypoint = ["${yardPython}/bin/standardizer"];   };
       bid-viewer    = { entrypoint = ["${yardPython}/bin/bid-viewer"];     };
       workflows     = { entrypoint = ["${yardPython}/bin/python"];
                         extraLayers = [busyboxLayer flyteWorkspaceLayer];  };
     };
   };
   ```

   Remove `nix2container` from yard's flake inputs. Remove hand-written just image recipes.

5. **Migrate zeus.**
   Replace `nix/images/default.nix` perSystem module with:

   ```nix
   jackpkgs.images = {
     registry = "ghcr.io/cavinsresearch/zeus";
     authMode = "ghcr";
     images = {
       klotho  = { packages = [python-nautilus entrypoint-wrapper];
                   entrypoint = ["${entrypoint-wrapper}/bin/entrypoint-wrapper"
                                 "${python-nautilus}/bin/klotho"]; };
       poseidon = { packages = [python-nautilus entrypoint-wrapper];
                    entrypoint = ["${entrypoint-wrapper}/bin/entrypoint-wrapper"
                                  "${python-nautilus}/bin/poseidon"]; };
     };
   };
   ```

   Remove `nix2container` from zeus's flake inputs. Remove hand-written just image recipes.
   Fix the `push-image` hardcoded name bug in the process.

6. **Write nix-unit tests** for `foldImageLayers` and option defaults.

______________________________________________________________________

## Related

- `addendalabs/yard` `docs/internal/designs/039-per-tool-container-images-manual-layering.md`
- `cavinsresearch/zeus` `docs/internal/decisions/085-nix-image-build-push-utility.md`
- jackpkgs ADR-001 (justfile recipe utilities)
- jackpkgs ADR-010 (justfile generation helpers)
- https://github.com/nlewo/nix2container
- https://blog.eigenvalue.net/2023-nix2container-everything-once/ (layer deduplication)

______________________________________________________________________

## Appendix A — Multiarch Images (Future Enhancement)

nix2container does **not** natively support building OCI manifest lists (multi-platform image
indexes). Each `buildImage` call produces a single-architecture image. To ship a multiarch image
to a registry, the standard approach is:

1. Build the `x86_64-linux` image and push it with a platform-specific tag
   (e.g., `myimage:latest-amd64`).
2. Build the `aarch64-linux` image and push it with a platform-specific tag
   (e.g., `myimage:latest-arm64`). This requires an aarch64 linux builder.
3. Use `skopeo` or `manifest-tool` to create a manifest list pointing at both, and push that
   as `myimage:latest`.

Steps 1 and 2 can each be driven by a `nix build .#images.<name>` + `skopeo-nix2container copy`
(same mechanism as single-arch). Step 3 requires an additional tool invocation.

In the Nix flake model, this would likely look like:

```nix
outputs.images.klotho          # x86_64-linux (current)
outputs.images.klotho-aarch64  # aarch64-linux (future)
# manifest list assembly: CI/CD step, not a nix output
```

Alternatively, a `outputs.imageManifests.klotho` output could hold a derivation that runs
`manifest-tool push from-args` after both arch images are pushed, but this requires network
access at build time (not pure).

**Prerequisite:** The `linuxSystem` option in the module must become `linuxSystems` (a list), and
the `images` attrset must be generated per system. The just recipes would loop over systems when
pushing.

**Recommendation:** Implement multiarch when deploying to a Kubernetes cluster that runs mixed-arch
node pools (e.g., graviton + x86 on EKS/GKE). For the current GKE x86_64 and local Docker use
cases, single-arch is sufficient.

______________________________________________________________________

Author: jmmaloney4
Date: 2026-02-20
PR: (pending)
