---
name: "jackpkgs"
description: "Personal Nix package repository"
category: "Nix Packages"
author: "Jack Maloney"
tags: ["nix", "packages", "ci"]
lastUpdated: "2025-06-18"
---

# AGENTS.md – Contract for Autonomous Coding Agents

> **If you are an LLM-powered agent** (Copilot coding-agent, ChatGPT Codex, Devin, Zencoder, etc.) **you MUST follow every rule below for every file you touch**. Violations will cause CI to fail and your PR to be closed.

---

## 0. Scope & Precedence
| Level | File path | Applies to | Priority |
|-------|-----------|-----------|----------|
| 1 | `system/user prompt` | Current session | 🥇 |
| 2 | Nearest `AGENTS.md` | Folder subtree | 🥈 |
| 3 | Repo-root `AGENTS.md` | Whole repo | 🥉 |
| 4 | `~/.codex/AGENTS.md` or `~/.codex/instructions.md` | Global user prefs | 🏅 |

When conflicts occur, **higher priority wins**.

---

## 1. Project Capsule
Jackpkgs collects custom Nix expressions for tools like CSharpier and Roon Server.
It provides overlays and modules so machines can easily consume these packages.

---

## 2. Directory Contract
<small>(Update this table whenever paths change.)</small>

| Path | Intent | Touch policy |
|------|--------|--------------|
| `/pkgs` | Package definitions | **Modifiable** |
| `/overlays` | Nix overlays | **Modifiable** |
| `/modules` | NixOS modules | **Modifiable** |
| `/lib` | Helper functions | **Modifiable** |
| `/.github` | CI workflows | **Modifiable** |

---

## 3. Tech Stack & Runtime
| Tool | Version | Install |
|------|---------|---------|
| Nix | 2.29.0 | `nix --version` |
| Bash | any | included in base image |
| CI image | `ubuntu-latest` | from GitHub Actions |

---

## 4. Coding Conventions
* **Language**: Nix expressions and shell scripts.
* **Style**: use `nixfmt` if available; shell scripts should be POSIX-compliant.
* **Comments**: Provide context for update scripts and unusual package logic.

---

## 5. Testing Strategy
* TODO: define unit or integration tests for packages.
* CI currently runs update workflows but no explicit tests.

---

## 6. Build & Run Recipes
```bash
nix-build -A packagename   # build specific package
nix-build                  # build all packages
```

Once drafted, run all programmatic checks locally; fix any issues before
committing `AGENTS.md` and opening the PR.
