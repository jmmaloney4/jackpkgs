# ADR-021: Python Dev Tools Pattern Documentation

## Status

Implemented (2026-01-30)

## Context

### Problem Statement

Users configuring Python projects with `jackpkgs` encounter issues where pre-commit hooks (specifically `mypy`) fail because the binary is missing from the Python environment. This happens when:

1. Users define a `default` environment without explicitly setting `includeGroups = true`
2. Dev tools like `mypy` are defined in `[dependency-groups]` (PEP 735) in `pyproject.toml`
3. The pre-commit module uses `pythonDefaultEnv` which lacks dev dependencies

The implementation is already correct—see ADR-018—but the pattern is not clearly documented.

### Root Cause

The `jackpkgs.python` module defaults `includeGroups` based on `editable`:

- `editable = true` → `includeGroups` defaults to `true` (dev dependencies included)
- `editable = false` → `includeGroups` defaults to `false` (production-only)

When users define a non-editable `default` environment without explicit `includeGroups = true`, the environment lacks dev tools. The `pre-commit.nix` module uses `pythonDefaultEnv` for the mypy hook, causing the hook to fail.

## Decision

Document the proper pattern clearly rather than change default behavior. This approach:

1. Maintains backward compatibility
2. Keeps explicit configuration (explicit is better than implicit)
3. Allows production-only `default` environments when desired

### Recommended Pattern

Users who want pre-commit hooks (mypy, ruff, etc.) to work should:

1. **Add dev tools to dependency groups in `pyproject.toml`:**

   ```toml
   [dependency-groups]
   dev = [
       "mypy>=1.11",
       "pytest>=8.0",
       "ruff>=0.1.0",
       "types-requests",  # type stubs
   ]
   ```

2. **Configure the `default` environment with `includeGroups = true`:**

   ```nix
   jackpkgs.python = {
     enable = true;
     workspaceRoot = ./.;
     environments.default = {
       name = "python-default";
       includeGroups = true;  # Include dev dependencies for pre-commit hooks
     };
   };
   ```

3. **Or use separate environments with an explicit `mypyPackage` override:**

   When you want a production-only `default` environment but still need pre-commit hooks to work,
   override `mypyPackage` to point to an environment that includes dev tools:

   ```nix
   jackpkgs.python = {
     enable = true;
     workspaceRoot = ./.;
     environments = {
       default = {
         name = "python-prod";
         # Production-only (includeGroups defaults to false)
       };
       dev = {
         name = "python-dev";
         editable = true;
         # Dev dependencies automatically included (includeGroups defaults to true)
       };
     };
   };

   # Override mypyPackage to use the dev environment for pre-commit hooks
   perSystem = { config, ... }: {
     jackpkgs.pre-commit.mypyPackage = config.jackpkgs.outputs.pythonEnvironments.dev;
   };
   ```

   **Important:** Without the `mypyPackage` override, the pre-commit mypy hook will fail because
   it defaults to using `pythonDefaultEnv` (the `default` environment), which lacks `mypy`.

## Environment Patterns Summary

| Environment Type        | `editable`                       | `includeGroups`   | Use Case                        | Pre-commit works?               |
| ----------------------- | -------------------------------- | ----------------- | ------------------------------- | ------------------------------- |
| **Production**          | `false`                          | `false` (default) | Deployment, minimal deps        | No (no mypy)                    |
| **Development**         | `true`                           | `true` (default)  | Local dev, devshell             | Yes (if used as default)        |
| **CI Checks**           | `false`                          | `true` (explicit) | Hermetic tests, pre-commit      | Yes                             |
| **Default + Hooks**     | `false`                          | `true` (explicit) | Simple setup with working hooks | Yes                             |
| **Separate prod + dev** | `default`: prod, `dev`: editable | —                 | Production default + dev shell  | Requires `mypyPackage` override |

### Pre-commit Hook Resolution

The pre-commit module (`pre-commit.nix`) resolves the mypy package as:

1. `jackpkgs.outputs.pythonDefaultEnv` (when `jackpkgs.python.environments.default` exists)
2. Falls back to `config.jackpkgs.pkgs.mypy` (standalone package from nixpkgs)

For the hook to find `mypy` in the default environment, the environment must include it. This happens when:

- `includeGroups = true` (or `editable = true` which implies it)
- The `[dependency-groups]` includes `mypy`

## Consequences

### Benefits

1. **No breaking changes** — Existing configurations continue to work
2. **Explicit configuration** — Users clearly see what's included in their environment
3. **Flexibility** — Supports both production-only and dev-inclusive patterns
4. **Clear documentation** — Users understand how to configure for their use case

### Trade-offs

1. **Initial confusion** — New users may not know to set `includeGroups = true`
   - Mitigation: This ADR and README updates document the pattern clearly
2. **Extra configuration** — One extra line needed for working pre-commit hooks
   - Mitigation: Simple one-line addition; follows explicit-is-better principle

## Related

- [ADR-018: Python Dependency Groups for CI Checks](./018-python-optional-dependencies.md) — `includeGroups` implementation
- [ADR-016: CI Checks Module](./016-ci-checks-module.md) — CI check environment selection

______________________________________________________________________

Author: Claude (Cursor)
Date: 2026-01-30
PR: cursor/python-dev-tools-documentation-6454
