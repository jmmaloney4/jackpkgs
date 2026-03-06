#!/usr/bin/env bash
# adr-conflict-check: validate ADR numbering in a directory.
#
# Checks performed:
#   1. Malformed filenames  – .md files whose names don't start with NNN-
#   2. Duplicate numbers    – two or more files share the same NNN prefix
#   3. Skipped numbers      – gaps in the NNN sequence (000 is reserved for
#                             the template and is excluded from gap detection)
#
# Exit 0 on success, exit 1 if any violation is found.

set -euo pipefail

# ── defaults ────────────────────────────────────────────────────────────────
ADR_DIR="docs/internal/decisions"

# ── argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --adr-dir)
      ADR_DIR="$2"
      shift 2
      ;;
    --adr-dir=*)
      ADR_DIR="${1#--adr-dir=}"
      shift
      ;;
    -h|--help)
      echo "Usage: adr-conflict-check [--adr-dir <path>]"
      echo ""
      echo "Options:"
      echo "  --adr-dir <path>  Directory containing ADR files (default: docs/internal/decisions)"
      exit 0
      ;;
    *)
      echo "adr-conflict-check: unknown argument: $1" >&2
      echo "Run 'adr-conflict-check --help' for usage." >&2
      exit 1
      ;;
  esac
done

# ── resolve directory ────────────────────────────────────────────────────────
if [[ ! -d "$ADR_DIR" ]]; then
  echo "adr-conflict-check: directory not found: $ADR_DIR" >&2
  echo "Set --adr-dir to the correct path for your project." >&2
  exit 1
fi

# ── collect .md files ────────────────────────────────────────────────────────
# Use find so we work correctly regardless of shell glob settings.
mapfile -t md_files < <(find "$ADR_DIR" -maxdepth 1 -name "*.md" -type f | sort)

if [[ ${#md_files[@]} -eq 0 ]]; then
  echo "adr-conflict-check: no .md files found in $ADR_DIR"
  exit 0
fi

# ── classify files ───────────────────────────────────────────────────────────
# Associative map: number (decimal, no leading zeros) -> space-separated basenames
declare -A num_to_files=()
malformed=()

for f in "${md_files[@]}"; do
  base="$(basename "$f")"

  # Skip README.md entirely – not an ADR.
  [[ "$base" == "README.md" ]] && continue

  # Extract leading NNN (exactly 3 digits).
  if [[ "$base" =~ ^([0-9]{3})- ]]; then
    raw="${BASH_REMATCH[1]}"
    num=$((10#$raw))   # strip leading zeros for arithmetic; use decimal base
    key="$raw"         # keep zero-padded key for display consistency
    if [[ -v num_to_files["$key"] ]]; then
      num_to_files["$key"]+=" $base"
    else
      num_to_files["$key"]="$base"
    fi
  else
    malformed+=("$base")
  fi
done

# ── check 1: malformed filenames ─────────────────────────────────────────────
errors=0

if [[ ${#malformed[@]} -gt 0 ]]; then
  echo "ERROR: Malformed ADR filenames in $ADR_DIR (must start with NNN-, e.g. 042-my-decision.md):"
  for f in "${malformed[@]}"; do
    echo "  $f"
  done
  echo ""
  errors=1
fi

# ── check 2: duplicate numbers ───────────────────────────────────────────────
declare -a dup_lines=()
for key in "${!num_to_files[@]}"; do
  files_for_key="${num_to_files[$key]}"
  # Count space-separated entries (files are space-separated in value)
  count=$(echo "$files_for_key" | wc -w)
  if [[ $count -gt 1 ]]; then
    dup_lines+=("  $key -> $files_for_key")
  fi
done

if [[ ${#dup_lines[@]} -gt 0 ]]; then
  echo "ERROR: Duplicate ADR numbers found in $ADR_DIR:"
  # Sort for stable output
  while IFS= read -r line; do
    echo "$line"
  done < <(printf '%s\n' "${dup_lines[@]}" | sort)
  echo ""
  errors=1
fi

# ── check 3: skipped numbers ─────────────────────────────────────────────────
# Build sorted list of all *real* ADR numbers (excluding 000, the template slot).
declare -a real_nums=()
for key in "${!num_to_files[@]}"; do
  n=$((10#$key))
  [[ $n -eq 0 ]] && continue   # 000 is always the template – skip
  real_nums+=("$n")
done

if [[ ${#real_nums[@]} -gt 0 ]]; then
  # Sort numerically
  mapfile -t sorted_nums < <(printf '%s\n' "${real_nums[@]}" | sort -n)

  min="${sorted_nums[0]}"
  max="${sorted_nums[-1]}"

  # Build a quick lookup set
  declare -A num_set=()
  for n in "${sorted_nums[@]}"; do
    num_set["$n"]=1
  done

  gaps=()
  for (( i = min; i <= max; i++ )); do
    if [[ ! -v num_set["$i"] ]]; then
      # Format as 3-digit zero-padded for display
      gaps+=("$(printf '%03d' "$i")")
    fi
  done

  if [[ ${#gaps[@]} -gt 0 ]]; then
    echo "ERROR: Skipped ADR numbers in $ADR_DIR (every number must have a file,"
    echo "       including rejected/superseded ADRs):"
    echo "  Missing: ${gaps[*]}"
    echo ""
    errors=1
  fi
fi

# ── result ───────────────────────────────────────────────────────────────────
if [[ $errors -eq 0 ]]; then
  count=${#num_to_files[@]}
  echo "adr-conflict-check: OK ($count ADR(s) in $ADR_DIR)"
  exit 0
else
  exit 1
fi
