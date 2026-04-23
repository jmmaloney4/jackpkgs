# ADR-023: Nix-compatible GitHub Packages authentication for npm

## Status

Proposed

## Context

### Problem

GitHub Packages requires authentication for **all** packages (public or private) when accessed via `npm.pkg.github.com`. Downstream consumers using `jackpkgs.nodejs` with private or scoped packages (e.g., `@jmmaloney4/sector7`) encounter build failures:

```
curl: (22) SSL certificate OpenSSL verify result: unable to get local issuer certificate (20)
curl: (22) The requested URL returned error: 401
```

This occurs during `buildNpmPackage` execution when npm tries to download from GitHub Packages without credentials.

### Constraints

- **Pure Nix sandbox**: Must work in hermetic builds (no network access during evaluation)
- **CI compatibility**: Must work across CI platforms (GitHub Actions, GitLab CI, etc.)
- **Security**: Must not leak secrets into Nix store or commit history
- **Reproducibility**: Builds must be deterministic
- **User experience**: Should not require manual `--impure` flags in production CI

### Related Work

- **ADR-020**: Migrate to buildNpmPackage — Uses `buildNpmPackage` and `importNpmLock`
- **ADR-022**: npm workspace lockfiles — Lockfile normalization for Nix compatibility
- **nixpkgs access-tokens**: Built-in GitHub auth mechanism for `fetchgit`/`fetchFromGitHub`

## Decision

We will document recommended patterns for GitHub Packages authentication in pure Nix builds, with platform-specific guidance.

### Recommended Approaches by Use Case

#### 1. GitHub Actions CI: Use `NIX_CONFIG access-tokens` (Primary)

**Best for:** GitHub Packages on GitHub Actions CI

```yaml
- uses: DeterminateSystems/nix-installer-action@v4
  with:
    extra-conf: |
      access-tokens = github.com=${{ secrets.GITHUB_TOKEN }}
```

**Implementation:**
- Nix configures `access-tokens` globally for the build
- Works automatically with `GITHUB_TOKEN` secret (auto-provided by GitHub Actions)
- No `--impure` flag required
- Pure Nix build

**Nix consumer doesn't need changes:** `buildNpmPackage` with `importNpmLock` works out of the box.

#### 2. Other CI Platforms: Prefetch `npmDepsHash` Locally

**Best for:** Non-GitHub CI (GitLab, CircleCI, Jenkins, etc.)

```bash
# Local: Generate hash with auth available in environment
nix run nixpkgs#prefetch-npm-deps ./package-lock.json
# Output: npmDepsHash = "sha256-AAAAAAAAAAA...";
```

```nix
# In flake: Use prefetched hash (no auth needed in CI)
nodeModules = pkgs.buildNpmPackage {
  pname = "node-modules";
  version = "1.0.0";
  src = ./.;
  npmDepsHash = "sha256-AAAAAAAAAAA...";  # Generated locally with auth
  installPhase = "cp -R node_modules $out";
};
```

**Workflow:**
1. Developer runs `prefetch-npm-deps` locally with GitHub PAT in environment
2. Commits hash to repository
3. CI builds purely using hash (no network access)
4. Hash must be updated when dependencies change

**Trade-off:** Requires manual hash updates when lockfile changes.

#### 3. Local Development: `sops-nix` or `agenix` (NixOS/Home Manager)

**Best for:** Local development on NixOS systems

```nix
# Using sops-nix
{
  sops.secrets.github_pat = {};
  home.sessionVariables = {
    GITHUB_TOKEN = "$(cat ${config.sops.secrets.github_pat.path})";
  };
  home.file.".npmrc".text = ''
    @jmmaloney4:registry=https://npm.pkg.github.com
    //npm.pkg.github.com/:_authToken=$GITHUB_TOKEN
  '';
}
```

**Features:**
- Encrypted secrets in repo
- No secrets in Nix store
- Works with `nix-shell` and `nix develop`
- Requires NixOS or Home Manager setup

#### 4. Local Development: `--impure` + Environment Variables

**Best for:** Quick local development, non-NixOS systems

```nix
{
  impureEnvVars = [ "GPM_TOKEN" ];  # Allow env var through sandbox
  npmConfigAttributes = {
    "@jmmaloney4:registry" = "https://npm.pkg.github.com";
    "_authToken" = builtins.getEnv "GPM_TOKEN";  # Read from environment
  };
}
```

```bash
# Build with impure flag
nix build .#package --impure
```

**Trade-offs:**
- Token may leak into Nix store paths (less secure)
- Requires `--impure` flag for flakes
- Simple for local dev, not for production

### Out of Scope

- Adding GitHub auth configuration to `jackpkgs.nodejs` module
  - Auth patterns are consumer-specific (different CI platforms, org policies)
  - Would increase jackpkgs complexity for minimal benefit
  - Downstream consumers can easily configure this themselves
- Publishing to npmjs.org (different design decision)

## Consequences

### Benefits

1. **Platform-appropriate solutions** — Best approach varies by CI platform
2. **No jackpkgs changes needed** — Purely documentation
3. **Secure options for production** — Multiple patterns available
4. **Simple local dev** — Impure mode for quick iteration

### Trade-offs

| Approach | Security | Usability | Reproducibility | Best For |
|----------|-----------|------------|------------------|-----------|
| `NIX_CONFIG access-tokens` | ✅ High | ✅ Medium | ✅ Pure | GitHub Actions |
| Prefetched hash | ✅ Highest | ⚠️ Complex | ✅ Pure | Non-GitHub CI |
| `sops-nix`/`agenix` | ✅ Highest | ⚠️ Setup required | ✅ Pure | Local dev (NixOS) |
| `--impure` + env vars | ❌ Low (leaks to store) | ✅ Easy | ❌ Impure | Local dev only |

### Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Consumers use insecure `--impure` pattern in CI | Medium | High | Document as "local dev only" in ADR |
| Token leaks into Nix store | Low | Medium | Warn in documentation; recommend access-tokens or hash approach |
| Hash updates forgotten | High | Medium | Add CI check for npmDepsHash outdatedness (future work) |
| Platform-specific docs become stale | Low | Medium | Keep examples minimal; reference nixpkgs docs |

## Alternatives Considered

### Alternative A — Add GitHub Auth Options to `jackpkgs.nodejs`

**Approach:** Extend nodejs module with GitHub PAT configuration options.

```nix
jackpkgs.nodejs = {
  enable = true;
  github = {
    token = "ghp_...";  # Would be in Nix store
    tokenFile = "/run/secrets/github_token";  # Better
  };
};
```

**Pros:**
- Convenient for consumers
- Single place to configure

**Cons:**
- Token in Nix store if string provided (security risk)
- TokenFile approach requires secret management anyway (same as `sops-nix`)
- Increases jackpkgs complexity
- Auth patterns vary wildly by platform (not one-size-fits-all)

**Why not chosen:** Auth is consumer-specific and platform-specific. Consumers can easily configure `npmConfigAttributes` themselves. Adding this to jackpkgs adds maintenance burden for limited benefit.

### Alternative B — Publish to npmjs.org Instead of GitHub Packages

**Approach:** Migrate npm packages from GitHub Packages to npmjs.org (public registry).

**Pros:**
- No authentication required for public packages
- Standard npm registry
- Better cache hit rate across all consumers

**Cons:**
- Outside scope of jackpkgs (consumer choice)
- May require org-wide migration
- Loses GitHub Packages integration (private packages)

**Why not chosen:** This is a consumer decision, not a jackpkgs design decision. We should support both public and private registries.

### Alternative C — Use `.netrc` File in Nix Build

**Approach:** Generate `.netrc` file during build and pass credentials.

```nix
{
  preBuild = ''
    cat > ~/.netrc << EOF
    machine npm.pkg.github.com login ${GITHUB_ACTOR} password ${GITHUB_TOKEN}
    EOF
    chmod 600 ~/.netrc
  '';
}
```

**Pros:**
- Standard npm auth mechanism
- Works across platforms

**Cons:**
- Requires environment variables (`--impure` flag)
- Token visible in build logs
- Still needs secret management

**Why not chosen:** Same drawbacks as env var approach; `access-tokens` or hash approach is better.

## Implementation Plan

### Phase 1: Document ADR

1. Create `docs/internal/designs/023-github-packages-auth.md`
2. Include code examples for all recommended patterns
3. Add platform-specific CI examples
4. Document trade-offs and security considerations

### Phase 2: Update README (Optional)

If consumers frequently encounter this issue, add a troubleshooting section:

```markdown
## Troubleshooting

### GitHub Packages Authentication

If you see `curl: (22) The requested URL returned error: 401` when using private GitHub Packages:

- **GitHub Actions CI**: Configure `NIX_CONFIG access-tokens` (see ADR-023)
- **Other CI**: Prefetch `npmDepsHash` locally (see ADR-023)
- **Local dev**: Use `sops-nix` or `--impure` mode (see ADR-023)
```

### Phase 3: Consider Adding CI Check (Future)

If hash-based approach becomes standard, add a CI check that:

1. Detects outdated `npmDepsHash` by comparing lockfile hash
2. Fails with helpful message: "Run `prefetch-npm-deps ./package-lock.json` to update"

## Related

- **ADR-020**: Migrate to buildNpmPackage — Uses `buildNpmPackage` and `importNpmLock`
- **ADR-022**: npm workspace lockfiles — Lockfile normalization
- **nixpkgs manual**: `access-tokens` configuration
- **nixpkgs `importNpmLock`**: Private registry support

---

Author: jackpkgs maintainers
Date: 2026-02-01
PR: (TBD)
