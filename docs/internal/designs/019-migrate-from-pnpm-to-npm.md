# ADR: Migrate from pnpm to npm (package-lock)

## Status
Proposed

## Context
`jackpkgs` currently defaults to and encourages `pnpm` for Node.js projects, including complex monorepos like `zeus` and `yard`. However, the `nodejs` module relies on `dream2nix`'s legacy API to build these environments. We have discovered that **`dream2nix` (legacy) does not implement a `pnpm-lock` translator**, causing build failures (see Issue #126).

Options considered:
1.  **Port to `dream2nix` v2**: Requires a complete architectural rewrite of the `nodejs` module (~200+ lines, loss of auto-discovery), deemed too high effort/risk (see Issue #125).
2.  **Implement `pnpm-lock` translator**: Non-trivial effort to implement and maintain a custom translator.
3.  **Switch to supported lockfile**: `dream2nix` natively supports `package-lock.json` (npm) and `yarn.lock` (Yarn v1).

## Decision
We will switch `jackpkgs` to use **npm** and **`package-lock.json`** exclusively. We will remove all `pnpm` support to enforce a single, working standard across all consumer projects.

### Rationale
*   **Compatibility**: `package-lock` is natively supported by `dream2nix`'s legacy API, including workspace support.
*   **Simplicity**: Enforcing "one way" reduces maintenance burden and tooling complexity.
*   **Stability**: npm is the industry standard; `package-lock.json` is stable and widely understood.
*   **Mitigation**: The primary downsides of npm (disk usage, install speed) are largely mitigated by Nix's store model and caching.

## Detailed Changes

### 1. Module: `jackpkgs.pnpm`
*   **Action**: **Delete** this module entirely.
*   **Reason**: It is already deprecated, and we are removing `pnpm` support.

### 2. Module: `jackpkgs.pulumi`
*   **Action**: Remove `pkgs.pnpm` from `jackpkgs.pulumi.ci.packages` and the default devshell.
*   **Reason**: Pulumi projects will now use `npm` (provided via `nodejs`). `pkgs.nodejs` includes the `npm` binary.

### 3. Module: `jackpkgs.nodejs`
*   **Option `packageManager`**: Remove this option. Hardcode internal logic to assume `npm`.
*   **Option `projectRoot`**: Keep.
*   **Translator**: Change from `"pnpm-lock"` to `"package-lock"`.
*   **DevShell**:
    *   Remove `pkgs.pnpm`.
    *   Ensure `pkgs.nodejs` is present (provides `npm`).
    *   Update `shellHook` to look for `node_modules/.bin` consistent with npm's structure (flat `node_modules` in root).

## Migration Guide for Consumers (`zeus`, `yard`, etc.)

1.  **Remove pnpm**: Delete `pnpm-lock.yaml` and `pnpm-workspace.yaml` (unless Pulumi requires workspace config, but npm uses `package.json` workspaces).
2.  **Configure npm workspaces**: Ensure root `package.json` has a `workspaces` field matching the old pnpm config.
    ```json
    "workspaces": [
      "libs/*",
      "services/*"
    ]
    ```
3.  **Generate lockfile**: Run `npm install` to generate `package-lock.json`.
4.  **Update CI/Scripts**: Replace `pnpm` commands with `npm`.
    *   `pnpm install` -> `npm install` (or `npm ci` in CI)
    *   `pnpm run <script>` -> `npm run <script>`
    *   `pnpm -r` -> `npm run <script> --workspaces` or `npm exec --workspaces -- ...`

## Consequences

### Trade-offs
*   **Loss**: `pnpm`'s disk efficiency (hard links) and strict dependency isolation (phantom deps).
*   **Gain**: Functional Nix integration via `dream2nix`.
*   **Gain**: Reduced tooling fragmentation.

### Functionality
*   **Workspaces**: `package-lock` translator supports workspaces. `dream2nix` will still discover workspace packages, provided `package-lock.json` is generated correctly.
*   **Legacy API**: This approach is fully compatible with the current `dream2nix` legacy branch usage.

### Failure Mode
Projects trying to use `pnpm` with the new `jackpkgs` version will fail (missing `pnpm` binary, ignored `pnpm-lock.yaml`). This meets the "fail fast" requirement.
