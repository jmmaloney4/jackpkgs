#!/usr/bin/env bash
# Claude Code statusline.
# Line 1: model, cwd, git branch, worktree, PR link/state.
# Line 2: context remaining, cache hit ratio, 5h/7d rate limits, effort level.

# Every metric is rounded with `printf '%.0f'`, whose operand is parsed by
# strtod() and is therefore LC_NUMERIC-sensitive. Under a comma-decimal locale
# (de_DE.UTF-8, fr_FR.UTF-8, ...) strtod("91.5") stops at the '.', bash writes
# "invalid number" and returns non-zero -- and since the call sites are
# `var=$(...)` assignments, `set -e` turns that into no statusline at all. This
# ships via writeShellApplication, which injects `set -euo pipefail`, so pin the
# numeric locale. Verified not to affect output: the UTF-8 separator is emitted
# as literal bytes through `printf "%b"`, which does no re-encoding, and is
# byte-identical under C and C.utf8.
export LC_ALL=C

input=$(cat)

# Fields are joined with \001, NOT tabs. Tab is an IFS *whitespace* character, so
# `IFS=$'\t' read` collapses runs of tabs into one delimiter -- any empty field in
# the middle then shifts every later field left (the worktree slot renders the PR
# review state, `cache` renders the PR number, and printf aborts on a non-number).
# \001 is non-whitespace, so empty fields are preserved. Do not "simplify" this
# back to `@tsv`.

tsv=$(echo "$input" | jq -r '
  [
    (.model.display_name // ""),
    (.workspace.current_dir // .cwd // ""),
    (.context_window.remaining_percentage // ""),
    (.rate_limits.five_hour.used_percentage // ""),
    (.rate_limits.seven_day.used_percentage // ""),
    (
      (.context_window.current_usage.cache_read_input_tokens // 0) as $cr
      | ((.context_window.current_usage.input_tokens // 0) + (.context_window.current_usage.cache_creation_input_tokens // 0) + $cr) as $tot
      | if $tot > 0 then (($cr / $tot) * 100) else "" end
    ),
    (.effort.level // ""),
    (.worktree.name // ""),
    (.pr.number // ""),
    (.pr.url // ""),
    (.pr.review_state // "")
  ] | join("\u0001")
')
IFS=$'\001' read -r model dir remaining rl5h rl7d cache_ratio effort wt_name pr_number pr_url pr_state <<<"$tsv"

base=$(basename "$dir")

branch=""
if git -C "$dir" --no-optional-locks rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  branch=$(git -C "$dir" --no-optional-locks branch --show-current 2>/dev/null)
fi

# color code: higher value is good (context remaining, cache ratio)
pct_color_high() {
  awk -v v="$1" 'BEGIN{ if (v=="") print "2"; else if (v>=50) print "32"; else if (v>=20) print "33"; else print "31" }'
}
# color code: lower value is good (rate limit usage)
pct_color_low() {
  awk -v v="$1" 'BEGIN{ if (v=="") print "2"; else if (v<50) print "32"; else if (v<80) print "33"; else print "31" }'
}

line1="\033[2m[$model]\033[0m \033[36m${base}\033[0m"
[ -n "$branch" ] && line1="$line1 \033[2m\033[33m(${branch})\033[0m"
[ -n "$wt_name" ] && line1="$line1 \033[35m[wt:${wt_name}]\033[0m"

if [ -n "$pr_number" ]; then
  pr_text="PR #${pr_number}"
  if [ -n "$pr_url" ]; then
    pr_seg="\033]8;;${pr_url}\033\\\\${pr_text}\033]8;;\033\\\\"
  else
    pr_seg="$pr_text"
  fi
  line1="$line1 \033[34m${pr_seg}\033[0m"
  if [ -n "$pr_state" ]; then
    case "$pr_state" in
    APPROVED | approved) state_color=32 ;;
    CHANGES_REQUESTED | changes_requested) state_color=31 ;;
    *) state_color=33 ;;
    esac
    line1="$line1 \033[${state_color}m(${pr_state,,})\033[0m"
  fi
fi

segs=()

if [ -n "$remaining" ]; then
  r_int=$(printf '%.0f' "$remaining")
  c=$(pct_color_high "$remaining")
  segs+=("\033[2mctx\033[0m \033[${c}m${r_int}%\033[0m")
fi

if [ -n "$cache_ratio" ]; then
  cr_int=$(printf '%.0f' "$cache_ratio")
  c=$(pct_color_high "$cache_ratio")
  segs+=("\033[2mcache\033[0m \033[${c}m${cr_int}%\033[0m")
fi

if [ -n "$rl5h" ]; then
  v_int=$(printf '%.0f' "$rl5h")
  c=$(pct_color_low "$rl5h")
  segs+=("\033[2m5h\033[0m \033[${c}m${v_int}%\033[0m")
fi

if [ -n "$rl7d" ]; then
  v_int=$(printf '%.0f' "$rl7d")
  c=$(pct_color_low "$rl7d")
  segs+=("\033[2m7d\033[0m \033[${c}m${v_int}%\033[0m")
fi

if [ -n "$effort" ]; then
  segs+=("\033[2meff\033[0m \033[2m${effort}\033[0m")
fi

line2=""
for s in "${segs[@]}"; do
  if [ -z "$line2" ]; then
    line2="$s"
  else
    line2="$line2 \033[2m│\033[0m $s"
  fi
done

output="$line1"
[ -n "$line2" ] && output="$output\n$line2"

printf "%b\n" "$output"
