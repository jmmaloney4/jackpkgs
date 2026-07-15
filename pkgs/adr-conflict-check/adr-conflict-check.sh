#!/usr/bin/env bash
# adr-conflict-check: validate ADR numbering in a directory.
#
# Checks performed:
#   1. Malformed filenames  – .md files whose names don't start with NNN-
#   2. Duplicate numbers    – two or more files share the same NNN prefix
#   3. Skipped numbers      – gaps in the NNN sequence (000 is reserved for
#                             the template and is excluded from gap detection)
#   4. Allowed skips        – explicit legacy gaps declared by the caller
#
# Exit 0 on success, exit 1 if any violation is found.

set -euo pipefail

# ── defaults ────────────────────────────────────────────────────────────────
ADR_DIR="docs/internal/decisions"
ALLOW_SKIPPED_RAW=""

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
  --allow-skipped)
    ALLOW_SKIPPED_RAW="$2"
    shift 2
    ;;
  --allow-skipped=*)
    ALLOW_SKIPPED_RAW="${1#--allow-skipped=}"
    shift
    ;;
  -h | --help)
    echo "Usage: adr-conflict-check [--adr-dir <path>]"
    echo ""
    echo "Options:"
    echo "  --adr-dir <path>  Directory containing ADR files (default: docs/internal/decisions)"
    echo "  --allow-skipped <csv>  Comma-separated ADR numbers allowed to be missing (e.g. 017,018,024)"
    exit 0
    ;;
  *)
    echo "adr-conflict-check: unknown argument: $1" >&2
    echo "Run 'adr-conflict-check --help' for usage." >&2
    exit 1
    ;;
  esac
done

declare -A allowed_skipped=()
if [[ -n $ALLOW_SKIPPED_RAW ]]; then
  IFS=',' read -r -a allowed_parts <<<"$ALLOW_SKIPPED_RAW"
  for raw_part in "${allowed_parts[@]}"; do
    part="$(printf '%s' "$raw_part" | tr -d '[:space:]')"
    [[ -z $part ]] && continue

    if [[ ! $part =~ ^[0-9]{3}$ ]]; then
      echo "adr-conflict-check: invalid allowed skipped ADR number: $part" >&2
      echo "Expected zero-padded 3-digit numbers, e.g. 017,018,024" >&2
      exit 1
    fi

    dec=$((10#$part))
    if [[ $dec -eq 0 ]]; then
      echo "adr-conflict-check: 000 cannot be listed in --allow-skipped" >&2
      exit 1
    fi

    allowed_skipped["$dec"]=1
  done
fi

# ── resolve directory ────────────────────────────────────────────────────────
if [[ ! -d $ADR_DIR ]]; then
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

  # Skip structural markdown files that are not ADR records.
  [[ $base == "README.md" || $base == "index.md" ]] && continue

  # Extract leading NNN (exactly 3 digits).
  if [[ $base =~ ^([0-9]{3})- ]]; then
    raw="${BASH_REMATCH[1]}"
    num=$((10#$raw)) # strip leading zeros for arithmetic; use decimal base
    key="$raw"       # keep zero-padded key for display consistency
    if [[ -v num_to_files["$key"] ]]; then
      num_to_files["$key"]+=$'\n'"$base"
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
  count=$(printf '%s\n' "$files_for_key" | wc -l)
  if [[ $count -gt 1 ]]; then
    dup_lines+=("  $key -> ${files_for_key//$'\n'/ }")
  fi
done

if [[ ${#dup_lines[@]} -gt 0 ]]; then
  echo "ERROR: Duplicate ADR numbers found in $ADR_DIR:"
  printf '%s\n' "${dup_lines[@]}" | sort
  echo ""
  errors=1
fi

# ── check 3: skipped numbers ─────────────────────────────────────────────────
# Build sorted list of all *real* ADR numbers (excluding 000, the template slot).
declare -a real_nums=()
for key in "${!num_to_files[@]}"; do
  n=$((10#$key))
  [[ $n -eq 0 ]] && continue # 000 is always the template – skip
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
  for ((i = min; i <= max; i++)); do
    if [[ ! -v num_set["$i"] && ! -v allowed_skipped["$i"] ]]; then
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
