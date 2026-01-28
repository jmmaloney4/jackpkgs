# ADR: Migrate from pnpm to npm (package-lock)

## Status
Accepted

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

1.  **Remove pnpm**: Delete `pnpm-lock.yaml` and `pnpm-workspace.yaml`.
    *   **Note**: Pulumi projects typically rely on Node resolution logic, which works natively with npm workspaces. You generally do *not* need `pnpm-workspace.yaml` unless you have custom scripts explicitly parsing it. Pulumi YAML runtime configuration may reference package managers but typically auto-detects based on the lockfile.
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

## Appendix A: Pulumi & Package Management

### Nix within Pulumi
Pulumi does not natively support Nix for package management. It relies on standard language package managers (npm, pip, go mod).
*   **Detection**: Pulumi detects the package manager via lockfiles (`package-lock.json`).
*   **Install**: Pulumi runs `npm install` if `node_modules` is missing.
*   **Execution**: Pulumi executes the Node.js runtime (e.g., `node bin/index.js`).

`jackpkgs` uses `dream2nix` to ensure that dependencies are built hermetically and provided to the environment. Switching to `package-lock.json` improves this integration because `dream2nix`'s legacy translator handles standard npm structures more reliably than pnpm's symlinked structures.

### Plugins & Hermeticity
Pulumi has two components: the **SDK** (npm package) and the **Binary Plugin** (Go binary).
*   **SDK**: Managed via `npm` (and thus `jackpkgs`/`dream2nix`).
*   **Plugins**: Managed by the Pulumi CLI, which downloads binaries matching the SDK version.

**Why we don't manage plugins with Nix**:
Managing plugins via Nix introduces a "Double Update Problem" where the `package.json` SDK version and the Nix derivation hash must be manually synchronized. This is fragile and high-maintenance.

**Our Approach**:
1.  **Self-Management**: Let Pulumi download plugins to `~/.pulumi/plugins` on first run.
2.  **Consistency**: Use `PULUMI_IGNORE_AMBIENT_PLUGINS=1` in our devshells. This forces Pulumi to ignore global system plugins (e.g. in `/usr/local/bin`) and only use the specific version downloaded for the project, ensuring the binary exactly matches the SDK version defined in `package-lock.json`.

## Appendix B: Dream2nix & Node Modules Structure

### Granular Builder Output
The `dream2nix` `nodejs-granular` builder (used by `jackpkgs`) does **not** output a flat `node_modules` at the top level of the store path. Instead, it nests dependencies under the package name to support multiple packages in the same environment.

Source reference: [`modules/dream2nix/nodejs-granular/devShell.nix`](https://github.com/nix-community/dream2nix/blob/main/modules/dream2nix/nodejs-granular/devShell.nix) defines the node modules path as:
```nix
nodeModulesDir = "${nodeModulesDrv}/lib/node_modules/${packageName}/node_modules";
```

### Implications for Jackpkgs
In `modules/flake-parts/nodejs.nix`, we configure the project name as `"default"`:
```nix
subsystemInfo = {
  # ...
  packageName = "default";
};
```

This results in the following store path structure for our `nodeModules` derivation:
```
<store-path>/lib/node_modules/default/node_modules/<dependency>
```

Our `checks.nix` logic handles this by checking for the nested path first:
```bash
if [ -d "$nm_store/lib/node_modules/default/node_modules" ]; then
   nm_root="$nm_store/lib/node_modules/default/node_modules"
else
   nm_root="$nm_store/lib/node_modules"
fi
```
This ensures that when we symlink `node_modules` in the sandbox, we are pointing to the directory containing the actual dependencies (`react`, `typescript`, etc.), not just a directory containing a single `default` folder.
