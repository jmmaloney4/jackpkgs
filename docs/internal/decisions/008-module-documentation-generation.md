# ADR-008: Module Documentation Generation

## Status

Proposed

## Context

### Problem

- jackpkgs exposes 10+ flake-parts modules (`fmt`, `just`, `pre-commit`, `shell`, `pulumi`, `quarto`, `python`, etc.) with extensive configuration options
- Current documentation lives only in `README.md` with manual maintenance
- Users need comprehensive, searchable documentation beyond copy-paste examples
- Module options need to stay synchronized with documentation as the codebase evolves
- Risk of documentation drift as modules gain new options or change behavior

### Constraints

- MUST use stable, well-tested Nix tooling (prefer official over experimental)
- MUST work with flake-parts module system (uses `mkDeferredModuleOption`, etc.)
- MUST integrate into existing flake structure without major refactoring
- MUST be reproducible across all supported platforms (Linux, macOS, x86_64, aarch64)
- SHOULD generate human-readable output (prefer Markdown over proprietary formats)
- SHOULD support local viewing and remote deployment

### Prior Art

- NixOS manual: uses `nixos-render-docs` and `nixosOptionsDoc` for module option documentation
- Home Manager: uses `nmd` (NixOS Module Documentation) tool to generate AsciiDoc → HTML
- flake-parts ecosystem: provides guidance on using `nixosOptionsDoc` with proper `defaultText` attributes
- Various flake projects: ad-hoc solutions ranging from manual README to custom scripts

## Decision

We will use **`nixosOptionsDoc` + mdBook** to auto-generate module documentation:

1. **MUST** use `lib.evalModules` to evaluate all flake-parts modules and extract option definitions
2. **MUST** use `pkgs.nixosOptionsDoc` to generate CommonMark (Markdown) documentation from evaluated options
3. **MUST** use mdBook to render the generated Markdown into a searchable, navigable static HTML site
4. **MUST** expose the documentation site as `packages.docs` in the flake
5. **SHOULD** organize documentation with separate pages per module group for better navigation
6. **SHOULD** include an introduction page explaining the flake-parts integration model

### Scope

- In-scope: flake-parts modules only (`modules/flake-parts/**`)
- Out-of-scope (for now): NixOS modules (`modules/nixos/`), Home Manager modules (`modules/home-manager/`), package documentation

### Deployment Plan

- MVP: Local builds via `nix build .#docs`
- Future: Deploy to Cloudflare Workers once `jmmaloney4/sector7` Pulumi component is production-ready
- The Cloudflare Workers deployment will use a reusable Pulumi component for static site hosting

## Consequences

### Benefits

- **Automation**: Documentation auto-generates from module option definitions (single source of truth)
- **Discoverability**: Searchable web interface with mdBook's built-in search
- **Type safety**: `nixosOptionsDoc` validates option structure during generation
- **Ecosystem alignment**: Uses official Nix tooling, familiar to NixOS/flake-parts users
- **Maintainability**: Changes to module options automatically reflected in docs
- **Reproducibility**: Nix ensures consistent builds across environments

### Trade-offs

- **Build step required**: Users/contributors must run `nix build .#docs` to view full documentation
- **Complexity**: Additional flake output and build logic vs. pure README maintenance
- **Evaluation overhead**: Documentation generation requires full module evaluation (adds ~5-10s to build)
- **Learning curve**: Contributors need to ensure `description` and `defaultText` are accurate

### Risks & Mitigations

- **Risk**: `lib.evalModules` may not handle flake-parts deferred options cleanly
  - **Mitigation**: Spike to validate evaluation works; flake-parts provides `mkDeferredModuleOption` specifically for this use case
- **Risk**: Missing `defaultText` attributes cause evaluation failures
  - **Mitigation**: Modules already have extensive `defaultText` coverage; add any missing ones during implementation
- **Risk**: Documentation drift if contributors forget to update `description` fields
  - **Mitigation**: Can add CI check to ensure all options have descriptions
- **Risk**: Cloudflare Workers deployment dependency on external project
  - **Mitigation**: Local builds work independently; deployment is optional enhancement

## Alternatives Considered

### Alternative A — nmd (Home Manager's Tool)

- **Pros**:
  - Battle-tested by Home Manager project
  - Produces polished, professional documentation out-of-the-box
  - Handles complex module structures well
- **Cons**:
  - More complex setup than `nixosOptionsDoc`
  - Produces AsciiDoc (less familiar than Markdown; requires additional tooling)
  - Overkill for project size (~10 modules vs. Home Manager's 100+)
  - Less flexible for customization without diving into AsciiDoc internals
- **Why not chosen**: Complexity outweighs benefits for jackpkgs' scale; prefer simpler, more maintainable solution

### Alternative B — viperML/frost

- **Pros**:
  - Designed specifically for Flake documentation
  - Modern approach tailored to flake-based projects
- **Cons**:
  - Repository does not exist or is no longer accessible on GitHub (404 error)
  - Likely abandoned or never released publicly
  - Too experimental/volatile for production use
  - No community adoption or support
- **Why not chosen**: Non-existent or abandoned project; violates constraint to use stable, well-tested tooling

### Alternative C — nixos-render-docs

- **Pros**:
  - Official NixOS documentation renderer
  - Powers the NixOS manual (proven at scale)
  - Produces high-quality HTML output
- **Cons**:
  - Designed specifically for NixOS project structure
  - Requires significant customization to adapt for flake-parts modules
  - Tightly coupled to NixOS manual build process
  - Steeper learning curve than `nixosOptionsDoc` alone
- **Why not chosen**: Overkill; `nixosOptionsDoc` provides the extraction, mdBook handles rendering more simply

### Alternative D — MkDocs + nixosOptionsDoc

- **Pros**:
  - Same `nixosOptionsDoc` foundation as chosen solution
  - Richer theming options (Material for MkDocs is excellent)
  - Strong Python ecosystem with many plugins
  - `mkdocs-flake` provides Nix integration
- **Cons**:
  - Python dependency (vs. Rust for mdBook)
  - Slightly heavier than mdBook
  - More configuration surface area
- **Why not chosen**: Very close second; mdBook is lighter and simpler for MVP. Can switch if theming needs grow.

### Alternative E — Manual README Maintenance (Status Quo)

- **Pros**:
  - Simple, no additional tooling
  - Already in place and working
  - Immediate edits without build step
- **Cons**:
  - Manual synchronization required (high drift risk)
  - Not searchable beyond browser Ctrl+F
  - Doesn't scale as module count/complexity grows
  - No structured option reference (types, defaults, descriptions intermixed with prose)
- **Why not chosen**: Does not solve the core problem of keeping documentation synchronized with code

## Implementation Plan

### Phase 1: MVP (Local Documentation Build)

1. **Spike** (0.5h): Validate `lib.evalModules` + `nixosOptionsDoc` works with flake-parts modules
2. **Implementation** (2-3h):
   - Add `packages.docs` to `flake.nix` `perSystem` outputs
   - Evaluate modules with `lib.evalModules`
   - Generate documentation with `nixosOptionsDoc`
   - Create mdBook structure (`book.toml`, `SUMMARY.md`, introduction page)
   - Wire generated CommonMark into mdBook chapters
   - Build static site with `pkgs.stdenv.mkDerivation`
3. **Validation** (0.5h):
   - Test `nix build .#docs` on Linux and macOS
   - Verify all modules appear with correct options
   - Check that search works
4. **Documentation** (0.5h):
   - Update `README.md` with "Documentation" section
   - Add build and local viewing instructions

### Phase 2: Cloudflare Workers Deployment (Future)

- **Prerequisite**: `jmmaloney4/sector7` reusable Pulumi component for Cloudflare Workers static sites
- **Tasks**:
  - Add Pulumi stack configuration for docs site
  - Integrate `nix build .#docs` output with Pulumi deployment
  - Set up custom domain (if applicable)
  - Add CI/CD to auto-deploy on main branch changes
- **Owner**: To be determined (depends on sector7 completion)

### Rollout Considerations

- No user-facing breaking changes (additive only)
- Contributors should ensure new module options include `description` and `defaultText`
- Can add pre-commit hook to validate option documentation completeness
- Documentation site can be soft-launched (no announcement) for testing before promotion

### Rollback

- If documentation generation fails, README.md remains as fallback
- Can disable `packages.docs` without impacting other flake functionality
- No migration/data loss concerns (generated output only)

## Related

- **ADR-004**: Project Root Resolution (affects how `projectRoot` is documented)
- **Issue**: (To be created: "Implement module documentation generation")
- **External dependency**: jmmaloney4/sector7 (Cloudflare Workers Pulumi component, future deployment)
- **Upstream**: flake-parts documentation generation guidance (https://flake.parts/generate-documentation)

______________________________________________________________________

Author: Jack Maloney\
Date: 2025-10-21\
PR: (To be added upon implementation)
