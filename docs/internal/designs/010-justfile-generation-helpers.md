# ADR-010: Justfile Generation Helpers

## Status

Proposed

## Context

The `modules/flake-parts/just.nix` module generates justfile content dynamically using Nix indented strings (`''...''`). During implementation of the GCP quota project feature (ADR-009), we encountered persistent justfile parsing errors in consumer projects:

```
error: Expected '@', '[', comment, end of file, end of line, or identifier, but found indent
 ——▶ /nix/store/.../infra.just:1:1
  │
1 │   # Authenticate with GCP and refresh ADC
  │ ^^
```

This error revealed that the generated justfiles had leading whitespace on every line, causing just's parser to fail since recipes must start at column 0.

### Root Cause: Nix Indented String Behavior

Nix's indented string syntax (`''...''`) strips common leading whitespace based on the position of the **closing `''`**. For example:

```nix
# This code (with 12-space closing ''):
justfile = ''
              # Recipe comment
              recipe:
                  command
            '';

# Produces this output (2 spaces of indentation):
  # Recipe comment
  recipe:
      command
```

The closing `''` is at column 12, content is at column 14, so Nix strips 12 spaces, leaving 2 spaces on all lines.

### The Formatter Problem

We attempted multiple fixes:
1. **Reducing indentation by 2 spaces** — formatter reverted changes
2. **Aligning content with closing `''`** — formatter re-indented content
3. **Manual spacing adjustments** — formatter applied its own rules

Each fix was either reverted by treefmt or resulted in a new commit/amend cycle. The indentation became extremely fragile, with any formatter run potentially breaking justfile generation.

### Additional Complexity

Some features use `lib.optionalString` for conditional content:

```nix
justfile = ''
  recipe:
  ${lib.optionalString condition ''
      : setup-command
  ''}    main-command
'';
```

This nested indented string pattern made it nearly impossible to predict the final output indentation, as each nested string has its own indentation-stripping behavior.

### Why Existing Solutions Don't Work

**Option A — Fight the formatter:**
- Pros: Keep existing syntax
- Cons: Fragile; breaks on formatter runs; unclear what "correct" indentation is; difficult to maintain

**Option B — Disable formatter for this file:**
- Pros: Allows manual indentation control
- Cons: Loses formatting benefits for rest of file; doesn't address underlying fragility

**Option C — Use regular strings with explicit `\n`:**
```nix
justfile = "# Comment\n" + "recipe:\n" + "    command\n";
```
- Pros: Explicit; no indentation issues
- Cons: Hard to read; verbose; mixing strings and interpolations is awkward

**Option D — Use lib.concatStringsSep directly everywhere:**
```nix
justfile = lib.concatStringsSep "\n" [
  "# Comment"
  "recipe:"
  "    command"
  ""
];
```
- Pros: Clear; no indentation issues; each line is explicit
- Cons: Repetitive; requires manual "    " for every command; verbose for complex recipes

## Decision

Add **helper functions** to abstract justfile recipe generation and eliminate indentation fragility:

```nix
mkRecipe = name: comment: commands:
  lib.concatStringsSep "\n" (
    ["# ${comment}" "${name}:"]
    ++ map (cmd: "    ${cmd}") commands
    ++ [""]
  );

optionalLines = cond: lines: if cond then lines else [];
```

Features SHOULD use these helpers when refactoring or adding new recipes. Existing code MAY be refactored incrementally to use helpers.

### Implementation

**Helper functions (module-level let binding):**
```nix
# Helper to build justfile recipes without indentation issues
# Usage: mkRecipe "recipe-name" "comment" ["cmd1" "cmd2"]
mkRecipe = name: comment: commands:
  lib.concatStringsSep "\n" (
    ["# ${comment}" "${name}:"]
    ++ map (cmd: "    ${cmd}") commands
    ++ [""]
  );

# Helper for conditional recipe lines
optionalLines = cond: lines: if cond then lines else [];
```

**Example usage:**
```nix
direnv = {
  enable = true;
  justfile = lib.concatStringsSep "\n" [
    (mkRecipe "reload" "Run direnv" [
      "${lib.getExe sysCfg.direnvPackage} reload"
    ])
    (mkRecipe "r" "alias for reload" [
      "@just reload"
    ])
  ];
};
```

**For recipes with conditional content:**
```nix
infra = {
  enable = cfg.pulumi.enable;
  justfile = lib.concatStringsSep "\n" (
    ["# Authenticate with GCP and refresh ADC"]
    ++ ["# (set GCP_ACCOUNT_USER to override username)"]
    ++ ["auth:"]
    ++ optionalLines (cfg.gcp.iamOrg != null) [
      "    : \${GCP_ACCOUNT_USER:=$USER}"
    ]
    ++ ["    ${lib.getExe sysCfg.googleCloudSdkPackage} auth login --update-adc"]
    ++ optionalLines (cfg.gcp.quotaProject != null) [
      "    ${lib.getExe sysCfg.googleCloudSdkPackage} auth application-default set-quota-project ${cfg.gcp.quotaProject}"
    ]
    ++ [""]
  );
};
```

## Consequences

### Benefits
- **Formatter-proof:** No indentation to mess up; formatters can't break the output
- **Explicit:** Each line is clearly defined as a list element
- **Predictable:** Output format is obvious from the code structure
- **Maintainable:** Recipe structure is clear; easy to add/remove commands
- **Composable:** `optionalLines` makes conditional content straightforward
- **Self-documenting:** `mkRecipe` makes it clear this is a justfile recipe

### Trade-offs
- **Different syntax:** New code uses a different pattern than existing code
- **Mixed styles:** During transition, file will have both old (indented string) and new (helper) styles
- **Slightly more verbose:** `mkRecipe` call + list vs. indented string
- **Learning curve:** Contributors need to understand the helpers

### Risks & Mitigations
- **Risk:** Contributors might not know about helpers and use indented strings
  - **Mitigation:** Document helpers with clear examples in comments; point to this ADR
- **Risk:** Existing recipes might still break if formatter changes indentation rules
  - **Mitigation:** Incrementally refactor existing recipes to use helpers
- **Risk:** Helpers might not cover all use cases (e.g., recipes with embedded scripts)
  - **Mitigation:** Keep `lib.concatStringsSep` as fallback for complex cases; extend helpers as needed

## Alternatives Considered

### Alternative A — Fix Indentation and Document Rules
- Use specific indentation (align content with closing `''`)
- Add pre-commit hook to verify indentation
- Document exact spacing rules
- Pros: Keep familiar indented string syntax
- Cons: Fragile; formatter may still interfere; requires constant vigilance
- Why not chosen: Already tried multiple times; formatter kept reverting changes

### Alternative B — Use pkgs.writeText for Recipes
- Write each recipe as a separate file using `pkgs.writeText`
- Concatenate files in justfile generation
- Pros: Complete isolation from Nix indentation; easy to test
- Cons: Huge refactor; files scattered across derivations; hard to see full justfile
- Why not chosen: Too complex; loses composability; overkill for the problem

### Alternative C — Switch to a Different Just Integration
- Use a different flake module for just that handles generation better
- Pros: Might have better abstractions
- Cons: Requires migration; may not solve fundamental issue; loses just-flake features
- Why not chosen: Problem is Nix indentation, not just-flake itself

### Alternative D — Raw Strings Only (No Helpers)
- Use `lib.concatStringsSep` directly everywhere without helpers
- Pros: Maximum explicitness; no abstractions
- Cons: Very verbose; lots of repetition; manual "    " everywhere
- Why not chosen: Too verbose; helpers improve readability significantly

## Implementation Plan

1. ✅ Add `mkRecipe` and `optionalLines` helpers to module-level let binding
2. Update one feature (e.g., `direnv`) to use helpers as proof of concept
3. Test generated justfiles in consumer project
4. Document helper usage in comments
5. Incrementally refactor remaining features (can be done over multiple PRs)
6. Update contribution guidelines to recommend helpers for new recipes

## Related

- Module: `modules/flake-parts/just.nix`
- ADR-001: Justfile Recipe Construction Utilities (may need to reference this ADR)
- ADR-009: GCP ADC Quota Project Configuration (feature that exposed the problem)
- Nix Manual: Indented String Literals - https://nixos.org/manual/nix/stable/language/values.html#type-string

---

Author: jack  
Date: 2025-10-21  
PR: #<tbd>

