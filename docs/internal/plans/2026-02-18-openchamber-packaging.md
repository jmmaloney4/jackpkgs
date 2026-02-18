# Plan: Implement OpenChamber Package

**Date**: 2026-02-18  
**ADR**: [ADR-026](../designs/026-openchamber-packaging-approach.md)

## Goal

Package OpenChamber CLI (`@openchamber/web`) using GitHub source + fixed-output derivation + bun.

## Implementation

### File: `pkgs/openchamber/default.nix`

#### 1. Change source fetcher

Replace `fetchurl` (npm tarball) with `fetchFromGitHub`:

```diff
- fetchurl,
+ fetchFromGitHub,

- src = fetchurl {
-   url = "https://registry.npmjs.org/@openchamber/web/-/web-${version}.tgz";
-   hash = "sha256-gMBXaFSLInxXCPOW5tDN7BrVUZWEb/WrTTum9YmFMks=";
- };
+ src = fetchFromGitHub {
+   owner = "btriapitsyn";
+   repo = "openchamber";
+   rev = "v${version}";
+   hash = lib.fakeHash;  # Bootstrap, then replace
+ };
```

#### 2. Add bun to inputs

```diff
  stdenv,
+ bun,
  nodejs,
```

#### 3. Update `nodeModules` derivation

- Use `bun` in `nativeBuildInputs`
- Replace npm commands with `bun install --frozen-lockfile`
- Set working directory to `packages/web` (monorepo structure)

```nix
nodeModules = stdenv.mkDerivation {
  pname = "${pname}-node-modules";
  inherit version src;

  nativeBuildInputs = [
    bun
    python3
    pkg-config
  ];

  buildInputs = [
    vips
  ];

  outputHashAlgo = "sha256";
  outputHashMode = "recursive";
  outputHash = lib.fakeHash;  # Bootstrap, then replace

  buildPhase = ''
    runHook preBuild

    cd packages/web
    bun install --frozen-lockfile

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    cp -r packages/web/node_modules $out

    runHook postInstall
  '';
};
```

#### 4. Update main derivation

- Copy from `packages/web` subdirectory
- Add bun to `nativeBuildInputs` (may need for runtime)

```nix
stdenv.mkDerivation {
  inherit pname version src;

  nativeBuildInputs = [
    bun
    nodejs
  ];

  buildPhase = ''
    runHook preBuild

    cp -r ${nodeModules} packages/web/node_modules
    chmod -R u+w packages/web/node_modules

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib/node_modules/@openchamber/web
    cp -r packages/web/. $out/lib/node_modules/@openchamber/web/

    mkdir -p $out/bin
    ln -s $out/lib/node_modules/@openchamber/web/bin/cli.js $out/bin/openchamber

    runHook postInstall
  '';

  meta = with lib; {
    description = "Web and desktop interface for OpenCode AI agent";
    homepage = "https://github.com/btriapitsyn/openchamber";
    license = licenses.mit;
    maintainers = [ ];
    platforms = platforms.linux ++ platforms.darwin;  # Start small
    mainProgram = "openchamber";
  };
}
```

### File: `flake.nix`

No changes needed - package already registered in `allPackages`.

## Bootstrap Process

1. Build with `lib.fakeHash` for both `src.hash` and `outputHash`
2. Run `nix build .#openchamber` - will fail with real hash for src
3. Replace `src.hash` with real hash, rebuild
4. Will fail with real hash for `nodeModules`
5. Replace `outputHash` with real hash, rebuild
6. Verify build succeeds

## Decisions

- **Bun version**: Latest from nixpkgs (`bun`)
- **Platforms**: Start with `platforms.linux ++ platforms.darwin`, expand if testing proves otherwise

## References

- [ADR-026: OpenChamber Packaging Approach](../designs/026-openchamber-packaging-approach.md)
- https://github.com/btriapitsyn/openchamber
