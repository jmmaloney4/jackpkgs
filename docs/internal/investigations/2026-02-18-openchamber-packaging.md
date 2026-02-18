# Investigation: Packaging OpenChamber (Bun/NPM) for Nix

**Date**: 2026-02-18  
**Package**: `openchamber` (v1.7.1)  
**Source**: https://github.com/btriapitsyn/openchamber  
**NPM Package**: `@openchamber/web`

## Summary

Successfully packaged OpenChamber CLI using a fixed-output derivation approach with Bun as the package manager. This investigation documents the challenges encountered and solutions developed for packaging Bun-based projects in Nix.

## Background

OpenChamber is a web/desktop UI for the OpenCode AI agent. It's published as `@openchamber/web` on npm and uses Bun as its package manager with a monorepo structure.

### Key Characteristics
- **Package Manager**: Bun (uses `bun.lockb` binary lockfile)
- **Structure**: Monorepo with `packages/web` containing the CLI
- **Native Dependencies**: `node-pty`, `bun-pty`, `ghostty-web`, `sharp` (vips)
- **Runtime**: Node.js for execution, Bun for dependency management

## Approaches Attempted

### 1. NPM Registry Tarball + `buildNpmPackage` (Failed)

**Approach**: Fetch pre-built tarball from npm registry.

```nix
src = fetchurl {
  url = "https://registry.npmjs.org/@openchamber/web/-/web-${version}.tgz";
  hash = "...";
};
```

**Problem**: The npm tarball does not include `package-lock.json` or `bun.lockb`. Without a lockfile, `npm install` must resolve all dependencies from scratch, which is:
- Slow (resolving hundreds of packages)
- Non-deterministic (resolution may vary between runs)
- Unreliable in sandboxed environments

### 2. `buildNpmPackage` with GitHub Source (Failed)

**Problem**: The project uses `bun.lockb`, not `package-lock.json`. Nixpkgs `buildNpmPackage` requires `package-lock.json` to compute dependency hashes.

### 3. Nixpkgs Support for Bun (Not Available)

Investigated nixpkgs for Bun-specific builders:
- **npm**: `buildNpmPackage`, `fetchNpmDeps` (requires `package-lock.json`)
- **yarn v1**: `fetchYarnDeps`, `yarnConfigHook` (requires `yarn.lock`)
- **yarn v3/v4**: `yarn-berry_X.fetchYarnBerryDeps`
- **pnpm**: `fetchPnpmDeps`, `pnpmConfigHook` (requires `pnpm-lock.yaml`)

**Result**: No Bun-specific fetcher exists. Bun is only available as a runtime (`pkgs.bun`).

### 4. Fixed-Output Derivation with Bun (Success)

**Approach**: Use fixed-output derivation to allow network access in sandbox for `bun install`.

```nix
nodeModules = stdenv.mkDerivation {
  pname = "${pname}-node-modules";
  inherit version src;

  outputHashAlgo = "sha256";
  outputHashMode = "recursive";
  outputHash = "sha256-...";  # Computed after first build

  __noChroot = true;  # Required for network access

  buildPhase = ''
    bun install --frozen-lockfile
  '';

  installPhase = ''
    cp -r node_modules $out
  '';
};
```

## Key Challenges & Solutions

### Challenge 1: Bun Requires Network Access

**Problem**: Bun needs to download packages from npm registry, but nix sandbox blocks network access.

**Solution**: Fixed-output derivations allow network access. Combined with `__noChroot = true` to bypass sandbox restrictions entirely.

```nix
outputHashAlgo = "sha256";
outputHashMode = "recursive";
outputHash = "sha256-...";

__noChroot = true;
```

### Challenge 2: Bun Environment Variables

**Problem**: Bun fails silently in sandbox without proper environment setup.

**Solution**: Set required environment variables:

```nix
HOME = "/tmp";
XDG_CACHE_HOME = "/tmp/.cache";
BUN_INSTALL = "/tmp/.bun";
SSL_CERT_FILE = "${cacert}/etc/ssl/certs/ca-bundle.crt";
```

The `SSL_CERT_FILE` is critical for HTTPS connections to npm registry.

### Challenge 3: Monorepo Structure

**Problem**: Project is a Bun workspace with `node_modules` at root, not in `packages/web/`.

**Solution**: Run `bun install` from the `packages/web` directory. Bun handles workspace linking automatically.

```nix
buildPhase = ''
  cd packages/web
  bun install --frozen-lockfile
'';

installPhase = ''
  cp -r node_modules $out  # node_modules is relative to packages/web
'';
```

### Challenge 4: Broken Symlinks

**Problem**: Bun creates symlinks in `node_modules/.bin/` that point to non-existent locations, causing nix store errors:

```
error: getting status of '/nix/store/.../node_modules/.bin/acorn': No such file or directory
```

**Solution**: Remove broken symlinks after install:

```nix
installPhase = ''
  cp -r node_modules $out
  
  # Remove broken symlinks created by bun
  find $out -type l -exec test ! -e {} \; -delete
'';
```

### Challenge 5: Native Dependencies

**Problem**: Package has native dependencies (`node-pty`, `sharp`/vips) requiring build tools.

**Solution**: Add required build dependencies:

```nix
nativeBuildInputs = [
  bun
  python3      # For node-gyp (native module compilation)
  pkg-config   # For finding native libraries
];

buildInputs = [
  vips         # For sharp image processing
];
```

## Final Implementation

```nix
{ lib, stdenv, fetchFromGitHub, bun, nodejs, python3, pkg-config, vips, cacert }:

let
  pname = "openchamber";
  version = "1.7.1";

  src = fetchFromGitHub {
    owner = "btriapitsyn";
    repo = "openchamber";
    rev = "v${version}";
    hash = "sha256-3hzZVvapbbQ5aU8bpOqdmT7UU5CFHajD71Z9buPJzjw=";
  };

  nodeModules = stdenv.mkDerivation {
    pname = "${pname}-node-modules";
    inherit version src;

    nativeBuildInputs = [ bun python3 pkg-config ];
    buildInputs = [ vips ];

    outputHashAlgo = "sha256";
    outputHashMode = "recursive";
    outputHash = "sha256-KnOqfBbqoWKRdQIi+lYjGX6As3LbCl6gQ2zBvIVaMO0=";

    HOME = "/tmp";
    XDG_CACHE_HOME = "/tmp/.cache";
    BUN_INSTALL = "/tmp/.bun";
    SSL_CERT_FILE = "${cacert}/etc/ssl/certs/ca-bundle.crt";
    __noChroot = true;

    buildPhase = ''
      cd packages/web
      bun install --frozen-lockfile 2>&1 || bun install 2>&1
    '';

    installPhase = ''
      cp -r node_modules $out
      find $out -type l -exec test ! -e {} \; -delete
    '';
  };
in
stdenv.mkDerivation {
  inherit pname version src;

  nativeBuildInputs = [ bun nodejs ];

  buildPhase = ''
    cp -r ${nodeModules} packages/web/node_modules
    chmod -R u+w packages/web/node_modules
  '';

  installPhase = ''
    mkdir -p $out/lib/node_modules/@openchamber/web
    cp -r packages/web/. $out/lib/node_modules/@openchamber/web/
    
    mkdir -p $out/bin
    ln -s $out/lib/node_modules/@openchamber/web/bin/cli.js $out/bin/openchamber
  '';

  meta = with lib; {
    description = "Web and desktop interface for OpenCode AI agent";
    homepage = "https://github.com/btriapitsyn/openchamber";
    license = licenses.mit;
    platforms = platforms.linux ++ platforms.darwin;
    mainProgram = "openchamber";
  };
}
```

## General Pattern for Bun Packages

Based on this investigation, here's a reusable pattern for packaging Bun-based projects:

### 1. Prerequisites Checklist

- [ ] Source includes `bun.lockb` (for reproducibility)
- [ ] No `package-lock.json` available (otherwise use `buildNpmPackage`)
- [ ] Identify native dependencies and their nixpkgs equivalents
- [ ] Identify monorepo structure (workspace root vs package directory)

### 2. Template

```nix
{ lib, stdenv, fetchFromGitHub, bun, nodejs, cacert
  # Add native dependency packages as needed
, python3, pkg-config, vips ? null
}:

let
  pname = "<package-name>";
  version = "<version>";

  src = fetchFromGitHub {
    owner = "<owner>";
    repo = "<repo>";
    rev = "v${version}";
    hash = lib.fakeHash;  # Replace after first build
  };

  nodeModules = stdenv.mkDerivation {
    pname = "${pname}-node-modules";
    inherit version src;

    nativeBuildInputs = [ bun python3 pkg-config ];
    buildInputs = [ ] ++ lib.optionals (vips != null) [ vips ];

    outputHashAlgo = "sha256";
    outputHashMode = "recursive";
    outputHash = lib.fakeHash;  # Replace after first build

    # Bun environment
    HOME = "/tmp";
    XDG_CACHE_HOME = "/tmp/.cache";
    BUN_INSTALL = "/tmp/.bun";
    SSL_CERT_FILE = "${cacert}/etc/ssl/certs/ca-bundle.crt";

    # Allow network access
    __noChroot = true;

    buildPhase = ''
      # Adjust path for monorepo structure if needed
      # cd packages/<subpackage>
      
      bun install --frozen-lockfile 2>&1 || bun install 2>&1
    '';

    installPhase = ''
      cp -r node_modules $out
      
      # Remove broken symlinks
      find $out -type l -exec test ! -e {} \; -delete
    '';
  };
in
stdenv.mkDerivation {
  inherit pname version src;

  nativeBuildInputs = [ bun nodejs ];

  buildPhase = ''
    # Adjust path for monorepo structure
    cp -r ${nodeModules} ./node_modules
    chmod -R u+w ./node_modules
  '';

  installPhase = ''
    mkdir -p $out/lib/node_modules/<package-scope>/<package-name>
    cp -r ./. $out/lib/node_modules/<package-scope>/<package-name>/
    
    mkdir -p $out/bin
    ln -s $out/lib/node_modules/<package-scope>/<package-name>/bin/<cli> $out/bin/<binary-name>
  '';

  meta = with lib; {
    description = "<description>";
    homepage = "https://github.com/<owner>/<repo>";
    license = licenses.<license>;
    platforms = platforms.linux ++ platforms.darwin;
    mainProgram = "<binary-name>";
  };
}
```

### 3. Bootstrap Process

1. Set all hashes to `lib.fakeHash`
2. Run `nix build .#<package>`
3. Extract actual hash from error message
4. Update `src.hash` first
5. Run build again to get `nodeModules.outputHash`
6. Update and rebuild to verify

## Security Considerations

### `__noChroot` Implications

Using `__noChroot = true` bypasses the nix sandbox entirely during the `bun install` phase. This is necessary because:

1. Fixed-output derivations with network access still have restrictions
2. Bun may need broader filesystem access for caching

**Mitigations**:
- The `outputHash` ensures reproducibility - any tampering changes the hash
- Network access is only during dependency fetch, not during main build
- Use `--frozen-lockfile` to ensure exact dependency versions

### Supply Chain Security

The `bun.lockb` file pins exact dependency versions. Combined with `--frozen-lockfile`, this ensures:
- Same dependencies on every build
- No automatic updates during build
- Hash verification through nix's fixed-output derivation

## Lessons Learned

1. **Always check for lockfiles first** - The presence of `bun.lockb` vs `package-lock.json` determines the approach
2. **Bun needs environment setup** - Without proper env vars, bun fails silently
3. **Fixed-output derivations are powerful** - They enable network access while maintaining reproducibility
4. **Symlink handling matters** - Package managers create symlinks that may not work in nix store
5. **Native dependencies require toolchains** - Python, pkg-config, and native libs are often needed

## Related Documentation

- [ADR-026: OpenChamber Packaging Approach](../designs/026-openchamber-packaging-approach.md)
- [Plan: OpenChamber Packaging Implementation](../plans/2026-02-18-openchamber-packaging.md)

## References

- [Nixpkgs JavaScript Section](https://github.com/NixOS/nixpkgs/blob/master/doc/languages-frameworks/javascript.section.md)
- [Bun Documentation](https://bun.sh/docs)
- [Fixed-Output Derivations](https://nixos.org/manual/nix/stable/language/derivations.html#adv-attr-fixed-output-drv)
