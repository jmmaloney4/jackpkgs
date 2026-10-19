#!/usr/bin/env bash
set -euo pipefail

CACHE_DIR="$1"
FILESYSTEM="$2"
FLOOR_PCT="$3"
TARGET_PCT="$4"
MIN_AGE_MIN="$5"
MAX_DEPTH="$6"

free_pct() {
  local avail_kb size_kb
  read -r avail_kb size_kb < <(df --output=avail,size "$FILESYSTEM" | tail -1)
  echo $((avail_kb * 100 / size_kb))
}

pct=$(free_pct)
echo "[$(date -Iseconds)] cache-target-pruner: ${pct}% free on $FILESYSTEM (floor=${FLOOR_PCT}%, target=${TARGET_PCT}%)"

if [ "$pct" -ge "$FLOOR_PCT" ]; then
  echo "  above floor, nothing to do"
  exit 0
fi

if [ ! -d "$CACHE_DIR" ]; then
  echo "  SKIP: $CACHE_DIR does not exist"
  exit 0
fi

now=$(date +%s)
min_age_secs=$((MIN_AGE_MIN * 60))

candidates_file=$(mktemp)
trap 'rm -f "$candidates_file"' EXIT

# Only ever selects directories that are themselves CACHEDIR.TAG roots (the
# Cargo/uv/etc convention for "delete freely, this is regenerated") -- never
# a sibling directory that happens to share a parent with one, so real
# working files (e.g. a scratch investigation dir with a nested target/)
# are never touched. -type f plus the Cache Directory Tagging Spec signature
# check means an ordinary file or directory that merely happens to be named
# CACHEDIR.TAG can never cause its parent to be treated as disposable.
while IFS= read -r -d '' tag; do
  if ! head -c 43 "$tag" 2>/dev/null | grep -q '^Signature: 8a477f597d28d172789f06886806bc55'; then
    continue
  fi
  d=$(dirname "$tag")
  # -xdev/-x/--one-file-system: never cross into a mount point nested below a
  # tagged cache root, so a bind mount or mounted volume there can't cause
  # this service to delete data outside the cache filesystem.
  # || true: a genuine find failure (not just empty output -- e.g. an
  # unreadable subdirectory) must not abort the whole run under set -e. A
  # deterministic failure here would otherwise abort at the same candidate
  # on every timer tick, forever, defeating the pruner. Empty/failed both
  # flow into the same "could not determine recency" skip below.
  newest=$(find "$d" -xdev -type f -printf '%T@\n' 2>/dev/null | sort -n | tail -1) || true
  newest=${newest%.*}
  if [ -z "${newest:-}" ]; then
    # Can't determine recency (find produced nothing -- an error, or a race
    # with the tag disappearing). For a deletion path, an indeterminate
    # result must fail toward "skip", never toward "looks oldest, delete it".
    echo "  SKIP $d (could not determine recency)"
    continue
  fi
  if [ "$((now - newest))" -lt "$min_age_secs" ]; then
    echo "  SKIP $d (written to within ${MIN_AGE_MIN}m -- may be an active build)"
    continue
  fi
  size_kb=$(du -skx "$d" 2>/dev/null | cut -f1) || true
  size_kb=${size_kb:-0}
  # NUL-delimited records: a tab/newline-delimited format would corrupt a
  # cache path containing a literal newline, and rm -rf would then act on a
  # truncated path.
  printf '%s\t%s\0' "$size_kb" "$d" >>"$candidates_file"
done < <(find "$CACHE_DIR" -xdev -maxdepth "$MAX_DEPTH" -type f -iname CACHEDIR.TAG -print0 2>/dev/null)

if [ ! -s "$candidates_file" ]; then
  echo "  no eligible cache dirs found (all recently active, or none present)"
  exit 0
fi

freed_kb=0
while IFS= read -r -d '' candidate; do
  size_kb=${candidate%%$'\t'*}
  d=${candidate#*$'\t'}
  pct=$(free_pct)
  if [ "$pct" -ge "$TARGET_PCT" ]; then
    echo "  reached target (${pct}% free), stopping"
    break
  fi
  echo "  RM $d ($((size_kb / 1024))M)"
  # Under set -e, --one-file-system leaving a nested mount point behind (a
  # non-zero exit, by design) would otherwise abort the whole run here and
  # strand every remaining candidate unprocessed.
  if ! rm -rf --one-file-system -- "$d"; then
    echo "  WARN: could not fully remove $d (nested mount point?) -- continuing"
  fi
  freed_kb=$((freed_kb + size_kb))
done < <(sort -z -t "$(printf '\t')" -k1,1 -rn "$candidates_file")

echo "[$(date -Iseconds)] cache-target-pruner complete: freed $((freed_kb / 1024))M, now $(free_pct)% free"
