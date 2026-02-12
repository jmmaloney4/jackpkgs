---
id: ADR-024
title: Mdformat Configuration
status: proposed
date: 2026-02-10
---

# ADR-024: Add mdformat with frontmatter and GFM plugins to default formatters

## Status

Accepted

## Context

Currently, `jackpkgs` provides standard formatters for Nix, Python, Rust, and other languages via `treefmt`, but it lacks a configured Markdown formatter. Projects consuming `jackpkgs` (like `zeus`) currently have to manually configure `mdformat` to ensure it handles common patterns like YAML frontmatter correctly.

Running a raw `mdformat` without plugins on files with YAML frontmatter (used by Jekyll, Hugo, Docusaurus, and our own ADR/Agent parsing) corrupts the metadata:

1. The `---` delimiters are converted to horizontal rules (underscores).
2. The YAML content is formatted as markdown text.

This requires every downstream project to manually wire up the `mdformat-frontmatter` plugin in their `flake.nix`, which is error-prone due to how `treefmt-nix` handles plugin wrapping.

## Decision

We will enable `programs.mdformat` in `treefmt.config` with a "batteries-included" configuration that supports modern GitHub-flavored markdown and metadata.

Specifically, we will include the following plugins by default:

1. **`mdformat-frontmatter`**: Preserves YAML frontmatter blocks.
2. **`mdformat-gfm`**: Supports GitHub Flavored Markdown extensions (tables, strikethrough, autolinks, task lists).
3. **`mdformat-footnote`**: Supports markdown footnotes (`[^1]`).

We will also apply the following configuration defaults:

- `end_of_line = "lf"`: Normalize markdown files to LF line endings for consistent cross-platform diffs.
- `number = true`: Use consecutive numbering for ordered lists (`1.`, `2.`, `3.`) instead of `1.`, `1.`, `1.`.
- `validate = true`: Validate markdown before writing changes so malformed input fails fast.
- `wrap = "keep"`: Do not forcibly wrap lines. This prevents breaking long links or code blocks.

## Consequences

### Benefits

- **Safety**: Prevents corruption of files with YAML frontmatter.
- **Consistency**: Ensures markdown formatting matches GitHub rendering (GFM) and supports common extensions.
- **Convenience**: Removes the need for downstream projects to manually configure markdown formatting.

### Trade-offs

- **Dependencies**: Adds Python dependencies (`mdformat` and plugins) to the formatter closure.

### Risks & Mitigations

- **Risk**: Existing markdown files in downstream projects might be reformatted significantly.
  - **Mitigation**: The `wrap = "keep"` setting minimizes diffs by preserving existing line breaks.

## Alternatives Considered

### Alternative A — Do nothing

- **Pros**: Zero maintenance.
- **Cons**: Users must manually configure `mdformat` or risk corrupting frontmatter.
- **Why not chosen**: The risk of data corruption (frontmatter) and the poor developer experience of manual configuration outweigh the maintenance cost.

### Alternative B — Use `prettier` for Markdown

- **Pros**: Popular in the JS ecosystem.
- **Cons**: `treefmt-nix` integration for Prettier can be heavier; `mdformat` is a Python tool which aligns well with our Python-heavy tooling.
- **Why not chosen**: `mdformat` is already the de facto choice in our ecosystem and has a dedicated Nix module in `treefmt-nix`.

## Implementation Plan

Modify `modules/flake-parts/fmt.nix` to include the `mdformat` configuration block:

```nix
        # Markdown
        programs.mdformat = {
          enable = true;
          inherit excludes;
          
          package = pkgs.mdformat;

          plugins = ps: [ 
            ps.mdformat-frontmatter
            ps.mdformat-gfm
            ps.mdformat-footnote
          ];

          settings = {
            end_of_line = "lf";
            number = true;
            validate = true;
            wrap = "keep";
          };
        };
```

## Related

- Issue: #148

______________________________________________________________________

Author: jmmaloney4
Date: 2026-02-09
