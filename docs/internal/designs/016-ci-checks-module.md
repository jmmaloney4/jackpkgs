# ADR-016: CI Checks Module

## Status

Proposed

## Context

### Problem

Currently, `nix flake check` quality gates must be defined locally in each consumer project. This typically involves ~100+ lines of Nix code defining pytest, mypy, and ruff checks. This pattern:

1. **Duplicates across projects** - Every jackpkgs consumer must reimplement the same check patterns
2. **Requires deep Nix knowledge** - Complex PYTHONPATH configuration, workspace discovery, per-package execution
3. **Misses TypeScript entirely** - Pulumi stacks using `pulumi.nix` have no type-checking in `nix flake check`
4. **Inconsistent with jackpkgs design** - jackpkgs provides environments (`python.nix`, `pulumi.nix`) but not the checks that use them

### Current State in jackpkgs

| Module | What it provides | Gaps |
|--------|-----------------|------|
| `python.nix` | Python environments, devshell fragments | No checks |
| `pulumi.nix` | Pulumi devshell with TypeScript tooling | No tsc check |
| `pnpm.nix` | Node.js/pnpm devshell | No checks |
| `fmt.nix` | treefmt formatting, ruff-check/ruff-format | Formatter, not CI check |
| `pre-commit.nix` | mypy hook, treefmt hook, nbstripout | Pre-commit hooks, not CI checks |

**Key distinction:**
- **Pre-commit hooks** run on staged files during development (fast feedback)
- **CI checks** run on entire codebase during `nix flake check` (comprehensive validation)

### Typical Consumer Implementation

Consumer projects typically implement checks like:

```nix
# In consumer's flake-module.nix
checks = {
  pytest = pkgs.runCommand "python-pytest" {...};
  ruff = pkgs.runCommand "python-ruff" {...};
  mypy = pkgs.runCommand "python-mypy" {...};
  # Missing: TypeScript checks
};
```

This requires:
- Manual PYTHONPATH configuration
- Dynamic workspace member discovery (parsing pyproject.toml)
- Per-package execution to avoid module name conflicts
- Coverage file redirection to `$TMPDIR`

### Why Now

1. **TypeScript gap** - Pulumi users discover TypeScript errors only at `pulumi up` time, not in `nix flake check`
2. **Pattern established** - Consumer projects have proven the check pattern works; time to generalize
3. **Pre-commit mypy exists** - jackpkgs already has mypy in `pre-commit.nix`; CI checks should follow
4. **Consistency** - jackpkgs provides the building blocks; should also provide the validation

### Constraints

- **Backward compatibility** - Existing consumer projects must continue to work unchanged
- **Opt-in** - Checks should be configurable, not forced on all consumers
- **Composable** - Projects may want to add custom checks alongside module-provided ones
- **Hermetic** - Checks must run in pure Nix sandbox (no network access)

---

## Decision

### Core Design

Add a new `checks.nix` flake-parts module to jackpkgs that provides standardized CI checks for Python and TypeScript workspaces.

### Module Structure

```
jackpkgs/modules/flake-parts/
├── checks.nix          # NEW: CI checks infrastructure
├── python.nix          # Existing: Python environments
├── pulumi.nix          # Existing: Pulumi devshell
├── pnpm.nix            # Existing: pnpm devshell
└── all.nix             # Add: import checks.nix
```

### Configuration Interface

```nix
# In consumer flake.nix
jackpkgs.checks = {
  enable = true;  # default: true when jackpkgs.python.enable or jackpkgs.pulumi.enable

  python = {
    enable = true;  # default: true when jackpkgs.python.enable
    pytest = {
      enable = true;
      extraArgs = ["--color=yes" "-v"];
    };
    mypy = {
      enable = true;
      extraArgs = [];
    };
    ruff = {
      enable = true;
      extraArgs = ["--no-cache"];
    };
  };

  typescript = {
    enable = true;  # default: true when jackpkgs.pulumi.enable
    tsc = {
      enable = true;
      # Discovers pnpm-workspace.yaml packages automatically
      # Or explicit package list:
      packages = null;  # null = auto-discover from pnpm-workspace.yaml
    };
  };
};
```

### Python Checks Implementation

The module MUST:

1. **Use the jackpkgs Python environment** - `config.packages.<python-env-name>` or build combined environment with dev tools
2. **Discover workspace members automatically** - Parse `pyproject.toml` `tool.uv.workspace.members` globs
3. **Execute per-package** - Avoid module name conflicts (multiple `tests/` directories)
4. **Configure PYTHONPATH** - Ensure uv2nix packages are discoverable
5. **Handle coverage files** - Redirect to `$TMPDIR`

```nix
# Conceptual implementation
checks.python-pytest = mkIf cfg.python.pytest.enable (
  pkgs.runCommand "python-pytest" {
    buildInputs = [pythonWithDevTools];
  } ''
    export PYTHONPATH="${pythonEnv}/lib/python3.12/site-packages:$PYTHONPATH"
    export COVERAGE_FILE=$TMPDIR/.coverage
    ${lib.concatMapStringsSep "\n" 
      (pkg: "(cd ${workspace}/${pkg} && pytest ${lib.escapeShellArgs cfg.python.pytest.extraArgs})")
      discoveredWorkspaceMembers}
    touch $out
  ''
);
```

### TypeScript Checks Implementation

The module MUST:

1. **Discover pnpm workspace packages** - Parse `pnpm-workspace.yaml`
2. **Require node_modules** - Fail with clear message if not present (like Python requires uv.lock)
3. **Run tsc --noEmit** - Type-check without emitting output
4. **Handle per-package tsconfig** - Each package may have its own configuration

```nix
# Conceptual implementation
checks.typescript-tsc = mkIf cfg.typescript.tsc.enable (
  pkgs.runCommand "typescript-tsc" {
    buildInputs = [pkgs.nodejs pkgs.nodePackages.typescript];
  } ''
    ${lib.concatMapStringsSep "\n"
      (pkg: ''
        echo "Type-checking ${pkg}..."
        if [ ! -d "${workspace}/${pkg}/node_modules" ]; then
          echo "ERROR: node_modules not found in ${pkg}. Run 'pnpm install' first."
          exit 1
        fi
        (cd ${workspace}/${pkg} && tsc --noEmit)
      '')
      discoveredTsPackages}
    touch $out
  ''
);
```

### Workspace Discovery

The module MUST provide workspace discovery utilities:

```nix
# For Python (uv workspace)
discoverPythonWorkspace = workspace: pyprojectPath:
  let
    pyproject = builtins.fromTOML (builtins.readFile pyprojectPath);
    memberGlobs = pyproject.tool.uv.workspace.members or [];
    # Expand globs like "tools/*" to ["tools/hello", "tools/ocr", ...]
  in
    expandGlobs workspace memberGlobs;

# For TypeScript (pnpm workspace)
discoverPnpmWorkspace = workspace: pnpmWorkspacePath:
  let
    # pnpm-workspace.yaml is YAML, need to handle differently
    # Option 1: Use pkgs.yq to parse at build time
    # Option 2: Require explicit package list (simpler)
  in
    ...;
```

### Check Output Naming

Checks MUST be named consistently:

- `checks.<system>.python-pytest`
- `checks.<system>.python-mypy`
- `checks.<system>.python-ruff`
- `checks.<system>.typescript-tsc`

This allows:
- `nix flake check` - Run all checks
- `nix build .#checks.aarch64-darwin.python-pytest` - Run specific check

---

## Consequences

### Benefits

1. **DRY** - Single implementation in jackpkgs, consumed by all projects
2. **Consistency** - All jackpkgs projects have same check structure
3. **TypeScript support** - Finally validates Pulumi stacks in `nix flake check`
4. **Reduced complexity** - Consumer projects don't need deep Nix knowledge
5. **Automatic discovery** - Adding new packages automatically adds them to checks
6. **Configurable** - Projects can tune or disable individual checks

### Trade-offs

1. **jackpkgs dependency** - Checks are tied to jackpkgs release cycle
2. **Less flexibility** - Standard checks may not fit all use cases
3. **Additional module** - More code to maintain in jackpkgs

### Risks & Mitigations

**R1: Workspace discovery complexity**
- Risk: Different projects have different layouts
- Mitigation: Support both auto-discovery and explicit package lists
- Fallback: Expose `discoveredWorkspaceMembers` for custom check definitions

**R2: TypeScript requires node_modules**
- Risk: node_modules not present in pure Nix sandbox
- Mitigation: Clear error message directing user to run `pnpm install`
- Alternative: Build node_modules via pnpm2nix (complex, deferred)

**R3: YAML parsing for pnpm-workspace.yaml**
- Risk: Nix doesn't have native YAML parser
- Mitigation: Use `pkgs.yq` at build time or require explicit package list
- Alternative: Convert pnpm-workspace.yaml to JSON in repo

**R4: Pre-commit vs CI check confusion**
- Risk: Users confused about when mypy runs
- Mitigation: Clear documentation; pre-commit = staged files, CI check = full codebase

---

## Alternatives Considered

### Alternative A — Keep Checks Project-Local

Continue requiring each consumer to define checks locally.

**Pros:**
- Maximum flexibility per project
- No jackpkgs changes required
- No coordination needed

**Cons:**
- Duplication across projects
- Each project reinvents workspace discovery
- TypeScript still missing unless manually added
- Inconsistent check implementations

**Why not chosen:** The pattern is mature enough to generalize; duplication is wasteful.

### Alternative B — Checks as Separate jackpkgs Input

Create `jackpkgs-checks` as separate flake, not part of core jackpkgs.

**Pros:**
- Decoupled release cycles
- Lighter core jackpkgs
- Could version independently

**Cons:**
- Another input for consumers to manage
- Tight coupling to jackpkgs internals anyway
- More fragmentation

**Why not chosen:** Checks are integral to the jackpkgs value proposition; should be included.

### Alternative C — Only Provide Check Utilities, Not Checks

Expose `lib.mkPythonCheck`, `lib.mkTypescriptCheck` utilities instead of configured checks.

**Pros:**
- Maximum flexibility
- No opinionated defaults
- Smaller module surface

**Cons:**
- Still requires consumer configuration
- Doesn't solve the duplication problem
- More boilerplate in consumer projects

**Why not chosen:** The goal is zero-config for common cases; utilities alone don't achieve this.

---

## Implementation Plan

### Phase 1: Python Checks

1. Create `modules/flake-parts/checks.nix` skeleton
2. Implement pytest check with workspace discovery
3. Implement ruff check
4. Implement mypy check
5. Add configuration options
6. Update `all.nix` to import checks.nix
7. Test with dogfooding in jackpkgs

**Effort:** 4-6 hours

### Phase 2: TypeScript Checks

1. Add `typescript.tsc` check definition
2. Implement pnpm-workspace.yaml discovery (or explicit list)
3. Handle node_modules requirement
4. Add configuration options
5. Test with Pulumi-using consumer projects

**Effort:** 3-4 hours

### Phase 3: Documentation

1. Add checks module documentation to jackpkgs README
2. Add migration guide for existing projects
3. Update module documentation

**Effort:** 1-2 hours

---

## Related

- **jackpkgs ADRs:**
  - ADR-013: CI DevShells (related pattern for minimal CI environments)
  - ADR-002: Python Environment Configuration
  - ADR-003: Python flake-parts Module

- **jackpkgs modules:**
  - `pre-commit.nix` - mypy hook (pre-commit, not CI)
  - `fmt.nix` - ruff via treefmt (formatter, not check)
  - `python.nix` - Python environments
  - `pulumi.nix` - Pulumi devshell

---

Author: Claude
Date: 2026-01-08
PR: TBD
