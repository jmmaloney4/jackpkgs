# ADR-001: Justfile Recipe Construction Utilities

## Status

Accepted

## Context

Constructing justfile recipes in `modules/flake-parts/just.nix` has been done via manual string concatenation. This is:

- Error-prone for multi-line scripts
- Inconsistent in indentation
- Hard to reuse and compose across features (direnv, infra, python, git, nix, quarto)

We want a standardized, reusable way to define recipes that guarantees correct indentation while accepting unindented arguments.

## Decision

Introduce two utilities for building justfile content:

- `constructRecipe` — Build a single recipe from structured inputs (name, optional parameters, body, dependencies, description, quiet flag), automatically indenting the body while accepting unindented arguments.
- `concatRecipes` — Combine multiple recipe strings with appropriate spacing between them.

The body may be provided as a single string or a list of lines. Empty lines and comments are preserved; executable lines are indented consistently.

## Consequences

### Benefits

- Consistent formatting and indentation across all recipes
- Reusable building blocks; simpler authoring and review
- Clear separation of recipe metadata (name/params/deps) from body content

### Trade-offs

- Adds a small abstraction layer over raw strings
- Contributors must learn the helpers’ parameters

### Risks & Mitigations

- Risk: Helpers become too opinionated. Mitigation: Keep interfaces minimal (indentation + simple concatenation) and accept raw strings/lists.

## Alternatives Considered

### Alternative A — Continue manual string concatenation

- Pros: No new abstractions
- Cons: Ongoing inconsistencies and formatting bugs
- Why not chosen: Doesn’t address the core issues

### Alternative B — External templating system

- Pros: Feature-rich templating
- Cons: Extra dependency and complexity for a simple need
- Why not chosen: Overkill

### Alternative C — Full DSL for recipes

- Pros: Very expressive
- Cons: High complexity and maintenance cost
- Why not chosen: Beyond current scope

## Implementation Plan

1. Add `constructRecipe` and `concatRecipes` helper functions in the just module scope.
2. Migrate existing recipes to the helpers incrementally.
3. Keep bodies authorable as unindented strings/lists; let helpers handle indentation.

## Related

- Module: `modules/flake-parts/just.nix`
- Feature areas: direnv, infra (Pulumi), python (nbstripout), git (pre-commit), nix (flake-iter), quarto

______________________________________________________________________

Author: jack
Date: 2025-09-20
PR: #<tbd>
