#!/usr/bin/env bash
set -euo pipefail

# Common release script functions
fetch_latest() {
  local main_remote="$1"
  local main_branch="$2"
  
  echo "📥 Fetching latest from $main_remote..." >&2
  git fetch --tags --prune "$main_remote"
  git fetch "$main_remote" "$main_branch":"refs/remotes/$main_remote/$main_branch"
  
  if ! git rev-parse --verify --quiet "$main_remote/$main_branch" >/dev/null; then
    echo "❌ Unable to find $main_remote/$main_branch. Ensure the remote and branch exist." >&2
    exit 1
  fi
}

get_latest_tag() {
  local latest_tag=$(git tag --sort=-version:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
  
  if [ -z "$latest_tag" ]; then
    echo "❌ No semver tags found. Please create an initial tag like v0.1.0 first." >&2
    exit 1
  fi
  
  echo "$latest_tag"
}

create_and_push_tag() {
  local new_tag="$1"
  local main_remote="$2"
  local main_branch="$3"
  
  local target_commit=$(git rev-parse "$main_remote/$main_branch")
  echo "🏷️  Creating tag $new_tag at $main_remote/$main_branch ($target_commit)..." >&2
  git tag -a "$new_tag" -m "Release $new_tag" "$target_commit"
  
  echo "📤 Pushing tag to remote..." >&2
  git push origin "$new_tag"
  
  echo "✅ Successfully created and pushed release tag: $new_tag" >&2
}

# Export functions for use in other scripts
export -f fetch_latest get_latest_tag create_and_push_tag
