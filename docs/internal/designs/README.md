# Architecture Decision Records (ADRs)

This directory contains Architecture Decision Records for `jackpkgs`.

## Purpose

ADRs document significant decisions and their rationale. They:

- Capture context, constraints, and the chosen approach
- Improve maintainability by explaining “why” behind designs
- Enable collaboration and continuity over time

## Location

All ADRs live in `docs/internal/designs/`.

## Naming Convention

Files are zero-padded and kebab-cased:

- `000-adr-template.md` — canonical template for new ADRs
- `001-some-decision.md`, `002-another-decision.md`, ...

## Status Values

Use one of the following in each ADR:

- Proposed
- Accepted
- Amended
- Superseded
- Deprecated
- Rejected

If an ADR is superseded, add cross-links in both directions.

## Process

1. Draft: copy `000-adr-template.md` to the next number and fill it in
2. Review: share for feedback; iterate until there’s consensus
3. Decide: set status to Accepted (or Rejected)
4. Implement: reference the ADR in PRs/issues
5. Evolve: when revisiting, write a new ADR and mark the old one Superseded

## Authoring Tips

- Prefer bullets over long prose; be explicit and concise
- Document trade-offs, not just the happy path
- Link to related PRs, issues, and prior ADRs
- Use MUST/SHOULD language for normative statements (RFC 2119)

## Template

Start from `000-adr-template.md` for all new ADRs.
