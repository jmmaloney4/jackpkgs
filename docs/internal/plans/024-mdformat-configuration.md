# Implementation Plan - ADR-024: Add mdformat configuration

This plan outlines the steps to implement the changes described in [ADR-024](../designs/024-mdformat-configuration.md) and [Issue #148](https://github.com/jmmaloney4/jackpkgs/issues/148).

## User Story

As a developer using `jackpkgs`, I want markdown files to be automatically formatted correctly—preserving YAML frontmatter and supporting GitHub Flavored Markdown (GFM)—so that I don't corrupt metadata or break rendering on GitHub.

## Proposed Changes

### Configuration

Modify `modules/flake-parts/fmt.nix` to include `mdformat` configuration within the `treefmt` settings. It should be placed alphabetically (e.g., after `programs.latexindent`).

#### Code Change

```nix
        # Markdown
        programs.mdformat = {
          enable = true;
          inherit excludes;
          
          # Use standard package
          package = pkgs.mdformat;

          # Plugins are configured via the plugins option which takes a function
          plugins = _: [ 
            pkgs.python3Packages.mdformat-frontmatter # CRITICAL: Preserves YAML frontmatter
            pkgs.python3Packages.mdformat-gfm         # Tables, task lists, strikethrough
            pkgs.python3Packages.mdformat-footnote    # Footnotes [^1]
          ];

          settings = {
            number = true;   # Use consecutive numbering (1., 2., 3.)
            wrap = "keep";   # Do not forcibly wrap lines
          };
        };
```

### Rationale

- **`mdformat-frontmatter`**: Prevents `---` delimiters from becoming horizontal rules and YAML from being formatted as markdown.
- **`mdformat-gfm`**: Ensures local formatting matches GitHub's rendering (tables, etc.).
- **`wrap = "keep"`**: Prevents large diffs and broken links/code blocks caused by aggressive wrapping.

## Verification Plan

### Automated Tests

1. **Check Configuration**: Run `nix flake check` to ensure the module evaluates correctly.
2. **Format Check**: Run `treefmt --fail-on-change` on the repo to see what would change.

### Manual Verification

1. **Frontmatter Test**:
   Create `test-frontmatter.md`:

   ```markdown
   ---
   title: Test
   date: 2023-01-01
   ---
   # Content
   ```

   Run `nix fmt test-frontmatter.md`. **Expectation**: Frontmatter is preserved exactly as is.

2. **GFM Test**:
   Create `test-gfm.md`:

   ```markdown
   | Col 1 | Col 2 |
   |---|---|
   | Val 1 | Val 2 |

   - [ ] Task 1
   - [x] Task 2
   ```

   Run `nix fmt test-gfm.md`. **Expectation**: Table is formatted nicely, task lists are preserved.

## Rollout Plan

- [x] Implement `programs.mdformat` block in `modules/flake-parts/fmt.nix`.
- [x] Run `nix flake check`.
- [x] Run `nix fmt` on the `jackpkgs` repo itself (expect some markdown reformatting).
- [x] Verify `docs/` and `README.md` are formatted correctly (no corrupted frontmatter).
- [x] Commit and push.

### Migration for Downstream Projects

Projects using `jackpkgs` (like `zeus`) can clean up their configs:

1. Remove local `treefmt.programs.mdformat` configuration.
2. Remove `.mdformat.toml` if the `number = true` default is acceptable.

## Questions / Risks

- **Risk**: Existing markdown files in this repo or downstream might be reformatted significantly if they weren't previously formatted.
  - *Mitigation*: The `wrap = "keep"` setting minimizes this disruption.
- **Risk**: Conflicts with existing local configurations in downstream projects.
  - *Mitigation*: Local `treefmt` config typically overrides imported modules, but they should ideally remove theirs to use the standard one.
