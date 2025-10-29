# ADR-013: CI DevShells

## Status

Proposed

## Context

GitHub Actions workflows and other CI systems need lightweight development shells containing only the minimal dependencies to run specific tools, rather than the full development environment with IDE tools, formatters, linters, and task runners.

### The Problem

The canonical use case is running Pulumi deployments in CI. The [toolbox pulumi.yml workflow](https://raw.githubusercontent.com/jmmaloney4/toolbox/refs/heads/main/.github/workflows/pulumi.yml) currently uses `nix develop .#pulumi` which includes the full development shell with:
- All base devshell tooling (just, jq, pre-commit hooks, formatters, etc.)
- Full development dependencies
- Extra utilities not needed in CI

This results in:
- Longer Nix evaluation times in CI
- Larger Nix store closures to download/cache
- Unnecessary dependencies that slow down CI runs
- Mixing of dev-time tools with runtime requirements

### Requirements

1. **Minimal closures**: CI shells MUST include only packages required for the specific operation
2. **Configuration reuse**: CI shells MUST reuse module configuration (backend URLs, env vars, etc.) from existing modules
3. **No duplication**: Avoid duplicating devshell definitions between dev and CI variants
4. **Discoverability**: CI shells should be easy to find and use (`devShells.ci-<module>`)
5. **Module ownership**: Each module should own its CI variant rather than centralizing CI logic
6. **Flexibility**: Users should be able to customize CI package lists (add, override, or exclude packages)

### Current Architecture

The devshell module uses a **composition pattern**:
- Each feature module (pulumi, python, quarto) creates its own devShell fragment
- The main devshell aggregates these via `inputsFrom`
- Base shells include development tooling from just-flake, pre-commit, treefmt, etc.

For the pulumi module specifically:
- **Dev shell includes**: `pulumi-bin`, `nodejs`, `pnpm`, `jq`, `just`, `google-cloud-sdk`, `ts-node`, `typescript`
- **CI actually needs**: `pulumi-bin`, `nodejs`, `pnpm`, `google-cloud-sdk`
- **Can eliminate**: `jq`, `just`, `ts-node`, `typescript` (dev-time conveniences)

## Decision

### Core Design

We MUST add CI devshells to feature modules following these principles:

1. **Location**: CI shells are defined directly in their respective feature modules (e.g., `pulumi.nix`), NOT in a separate `ci.nix` module

2. **Naming**: CI shells MUST be named `devShells.ci-<module>` to put the "ci" prefix first for easy discovery

3. **Activation**: CI shells are exported whenever their parent module is enabled (e.g., `jackpkgs.pulumi.enable = true`)
   - No separate enable flag initially
   - Can add `jackpkgs.<module>.ci.enable` in the future if needed

4. **Package Management**: Use a **simple package list** pattern:
   ```nix
   jackpkgs.pulumi.ci.packages = mkOption {
     type = types.listOf types.package;
     default = with pkgs; [
       pulumi-bin
       nodejs
       pnpm
       google-cloud-sdk
     ];
     description = "Packages included in the ci-pulumi devshell";
   };
   ```

5. **Environment Variables**: CI shells MUST include only relevant environment variables from the parent module
   - Include: Configuration (backend URLs, secrets provider, etc.)
   - Exclude: Development conveniences unless specifically needed

6. **Phased Rollout**: Start with `ci-pulumi` to establish the pattern, then expand to other modules

### Package Customization Pattern

Users can customize CI packages by **overriding the entire list**:

```nix
# Override completely
jackpkgs.pulumi.ci.packages = with pkgs; [
  pulumi-bin
  nodejs
  # Removed pnpm and google-cloud-sdk
];

# Add packages (requires reference to default)
jackpkgs.pulumi.ci.packages =
  config.jackpkgs.pulumi.ci.packages ++ [ pkgs.myExtraTool ];
```

**Excluding specific packages is awkward** - users must override the complete list. This is acceptable because:
- Excluding packages is a rare operation
- Most users will use defaults or only add packages
- The simple pattern is easier to understand and maintain

### Example: pulumi.nix Implementation

```nix
# In options section (perSystem):
jackpkgs.pulumi.ci = {
  packages = mkOption {
    type = with types; listOf package;
    default = with pkgs; [
      pulumi-bin
      nodejs
      pnpm
      google-cloud-sdk
    ];
    defaultText = literalExpression ''
      with pkgs; [
        pulumi-bin
        nodejs
        pnpm
        google-cloud-sdk
      ]
    '';
    description = "Packages included in the ci-pulumi devshell";
  };
};

# In config section (perSystem):
devShells.ci-pulumi = pkgs.mkShell {
  packages = config.jackpkgs.pulumi.ci.packages;

  env = {
    PULUMI_IGNORE_AMBIENT_PLUGINS = "1";
    PULUMI_BACKEND_URL = cfg.backendUrl;
    PULUMI_SECRETS_PROVIDER = cfg.secretsProvider;
  };

  # Note: No shellHook, no inputsFrom, minimal surface
};
```

### What Gets Excluded from CI Shells

Compared to the full development shell, CI shells MUST NOT include:

- Base development tooling (just, pre-commit, treefmt)
- IDE support tools (LSPs, formatters)
- Development convenience utilities (jq for pulumi)
- TypeScript development tools (ts-node, typescript) unless required at runtime
- Interactive shell enhancements

### Usage in CI

```yaml
# In GitHub Actions workflow
- name: Pulumi preview
  run: nix develop .#ci-pulumi --command pulumi preview

# Compared to current (heavier):
- name: Pulumi preview
  run: nix develop .#pulumi --command pulumi preview
```

## Consequences

### Benefits

1. **Faster CI runs**: Smaller closures mean faster downloads and evaluation
2. **Clearer separation**: Explicit distinction between dev and CI requirements
3. **Module ownership**: Each module defines its own CI needs - no central coordination
4. **Configuration reuse**: CI shells automatically inherit module configuration
5. **Gradual adoption**: Can add CI shells to modules incrementally
6. **Standard pattern**: Establishes a clear pattern for future modules

### Trade-offs

1. **More options per module**: Each module gains a `ci.packages` option (more surface area)
2. **Potential duplication**: Package lists are separate from dev shells (but unavoidable)
3. **Awkward exclusion**: Removing specific packages requires full override (acceptable trade-off)
4. **No automatic sync**: Changes to dev requirements don't auto-update CI requirements (feature, not bug)

### Risks & Mitigations

**Risk**: CI shells drift from actual CI needs over time
- **Mitigation**: Document CI shell contents in module documentation; test in actual CI

**Risk**: Users confused about when to use `.#<module>` vs `.#ci-<module>`
- **Mitigation**: Clear documentation and naming convention; CI workflows serve as examples

**Risk**: Package exclusion pattern is too awkward
- **Mitigation**: Monitor usage; if exclusion becomes common, can add `excludePackages` in future ADR

## Alternatives Considered

### Alternative A — Per-Module CI Variants (Separate Outputs)

Each module exposes both `pulumiDevShell` and `pulumiCIDevShell` as outputs:

```nix
jackpkgs.outputs.pulumiDevShell = pkgs.mkShell { ... };
jackpkgs.outputs.pulumiCIDevShell = pkgs.mkShell { ... };
```

**Pros:**
- Each module owns both dev and CI shells
- No new top-level outputs

**Cons:**
- Adds many new outputs to the module interface
- Not discoverable via standard `nix flake show`
- Users would still need to map outputs to devShells for standard usage
- We already expose the main devshell at the top level; this breaks that pattern

**Why not chosen:** Doesn't follow the existing pattern of exposing shells as `devShells.*` at the flake level

### Alternative B — Central CI Module

Create a new `ci.nix` module that references package lists from other modules:

```nix
# In pulumi.nix
jackpkgs.outputs.pulumiCIPackages = [ ... ];

# In ci.nix
devShells.ci-pulumi = pkgs.mkShell {
  packages = config.jackpkgs.outputs.pulumiCIPackages;
};
```

**Pros:**
- Centralized CI logic - all CI shells in one place
- Clear separation between CI and dev modules

**Cons:**
- Adds coordination between modules (pulumi.nix must export packages for ci.nix)
- CI shells defined separately from their feature implementations
- Extra indirection makes code harder to follow
- Still need `pulumiCIPackages` output in each module anyway

**Why not chosen:** Adds unnecessary coordination and indirection; modules should own their complete interface

### Alternative C — Transformation Layer

Add a function that strips dev tools from existing devShells:

```nix
devShells.ci-pulumi = stripDevTools config.jackpkgs.outputs.pulumiDevShell {
  removePackages = [ just jq ts-node ];
};
```

**Pros:**
- DRY - reuses existing shells
- Env vars automatically inherited
- Declarative filtering

**Cons:**
- Complex to implement package filtering reliably in Nix
- Still pulls in `inputsFrom` dependencies (pre-commit, treefmt, etc.)
- Hard to reason about what's actually in the final shell
- Package matching by derivation is fragile
- Doesn't actually solve the problem (can't strip `inputsFrom`)

**Why not chosen:** Technical limitations make this impractical; explicit definitions are clearer

### Alternative D — NixOS-Style (defaultPackages + extraPackages + excludePackages)

Use the NixOS `environment.systemPackages` pattern:

```nix
jackpkgs.pulumi.ci = {
  defaultPackages = mkOption { default = [ pulumi-bin nodejs pnpm gcloud ]; };
  extraPackages = mkOption { default = []; };
  excludePackages = mkOption { default = []; };
};

packages = lib.subtractLists
  cfg.ci.excludePackages
  (cfg.ci.defaultPackages ++ cfg.ci.extraPackages);
```

**Pros:**
- All three operations (override, add, exclude) are clean
- Well-understood pattern from NixOS
- `lib.subtractLists` is built-in and reliable

**Cons:**
- Three options per module instead of one (3x API surface)
- More complexity to document and understand
- Overkill for the rare case of package exclusion

**Why not chosen:** Excluding packages is rare enough that the added complexity isn't justified

## Implementation Plan

### Phase 1: Establish Pattern with Pulumi

1. Add `jackpkgs.pulumi.ci.packages` option to `modules/flake-parts/pulumi.nix`
2. Define `devShells.ci-pulumi` with minimal packages
3. Include only relevant environment variables (PULUMI_*, no development conveniences)
4. Document in module documentation
5. Update toolbox workflow to use `nix develop .#ci-pulumi`

### Phase 2: Expand to Other Modules (Future)

Once the pattern is validated with pulumi:

1. Add `jackpkgs.python.ci.packages` for CI Python environments
2. Add `jackpkgs.quarto.ci.packages` for CI document rendering
3. Document the pattern in general module development guidelines

### Phase 3: Optional Enhancements (As Needed)

If usage patterns reveal needs:

1. Add per-module `jackpkgs.<module>.ci.enable` flag if selective CI shells are needed
2. Add `excludePackages` option if exclusion becomes common
3. Add common CI utilities option (git, gh, etc.) if patterns emerge

### Testing

1. Build ci-pulumi shell: `nix build .#ci-pulumi`
2. Compare closure size: `nix path-info -rsSh .#ci-pulumi .#pulumi`
3. Verify environment variables are set correctly
4. Test in actual CI workflow (toolbox repository)

## Related

- **Related ADRs:**
  - ADR-001: Justfile Recipe Utilities (just is excluded from CI shells)
  - ADR-010: Justfile Generation Helpers (just recipes not needed in CI)

- **Future ADRs:**
  - CI shells for python module
  - CI shells for quarto module
  - Common CI utilities pattern (if needed)

- **External References:**
  - [toolbox pulumi.yml workflow](https://github.com/jmmaloney4/toolbox/blob/main/.github/workflows/pulumi.yml)
  - [Nix devShell documentation](https://nixos.org/manual/nix/stable/command-ref/new-cli/nix3-develop.html)

---

Author: Claude Code (with @jmmaloney4)
Date: 2025-10-28
PR: TBD
