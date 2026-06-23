# ADR-041: Pulumi Drift Report Tool

- Status: Proposed
- Date: 2026-05-24
- Related: jackpkgs Pulumi package set, downstream Pulumi monorepos

## Context

Several owned repositories use Pulumi stacks spread across multiple project directories. When branch state changes, the useful question is not just "does `pulumi up` want to do work?" but "which resources in which stacks will change if this branch lands?"

Today that answer is scattered across ad hoc local commands. The result is predictable:

- people inspect only one stack and miss the rest
- preview output is human-oriented and hard to aggregate
- drift from the provider and changes from the branch get conflated
- there is no standard report format for CI or local review

We want a small Python tool that can live in jackpkgs, run against a repo checkout, and produce a stack-by-stack report of the resources Pulumi would change.

## Decision

Add a Python CLI package, `pulumi-drift-report`, to jackpkgs.

The tool will:

- discover Pulumi project directories under a given root
- enumerate the stacks for each project with `pulumi stack ls --json`
- run a preview/refresh pass for each stack
- parse Pulumi's JSON output into a stable internal model
- emit either a human-readable report or JSON

The initial implementation will use the Pulumi CLI via subprocess, not the Automation API.

## Why Python

Python is the simplest fit for this kind of orchestration tool:

- subprocess + JSON parsing are first-class
- no extra runtime beyond what downstream repos already use for tooling
- easy to package in jackpkgs and easy to test with fake CLI stubs
- a PEP 420 namespace package matches the existing `jmmaloney4.tools.*` layout used in `garden`

## Output strategy

Pulumi's JSON preview/refresh output is the right source of truth for machine parsing.

The tool will parse the structured JSON produced by the CLI and reduce it to a smaller report model containing:

- stack identity
- project path/name
- preview and refresh summaries
- per-resource operations that are not `same`
- command failures, if any

If the CLI version only supports the older JSON event mode, the parser can be extended to ingest JSONL events as a fallback.

## Tradeoffs

### Pros

- keeps the tool small and explicit
- avoids pulling in Pulumi Automation SDK complexity
- works for any repo that already uses the CLI
- produces output that can be used locally and in CI

### Cons

- depends on the Pulumi CLI being installed
- JSON schema is CLI-version-dependent, so parsing needs to be tolerant
- the first version will still rely on the user's Pulumi auth and backend setup

## Scope boundary

This tool is for reporting, not remediation.

It will not:

- apply changes
- refresh state automatically unless explicitly requested
- try to infer which changes are "good" or "bad"
- manage secrets or backend configuration

## Follow-up ideas

- add a CI-friendly machine-readable summary file
- support filtering by stack name or project path
- optionally group changes by resource type or provider
- allow a `--changed-files` mode to narrow which projects are scanned
