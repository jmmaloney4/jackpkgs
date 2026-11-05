# git-bot-identity — print shell exports for the launching bot's git identity.
#
# Never writes `git config --local user.*`. Worktrees share one `.git/config`;
# repo-local identity would leak to Jack's commits. Set per-process env instead.
#
# Env var convention (launching bot SHOULD set these on the cloud-agent launch):
#
#   GROKBOT_GIT_NAME   Display name, e.g. `wiesner (Shared Patterns Maintainer)`.
#   GROKBOT_GIT_EMAIL  Email, e.g. `wiesner@bots.roomofrequirement.xyz`.
#                      Cavins bots: `<name>@bots.cavinsresearch.io`.
#
# Usage:
#   eval "$(git-bot-identity)"          # default: print export lines on stdout
#   git-bot-identity --exec -- git commit -m "..."
#   git-bot-identity --help
#
# If GROKBOT_GIT_NAME/EMAIL are unset, falls back to the latest `Bot:` trailer
# in the last 50 commits (email: `<bare>@$GROKBOT_GIT_EMAIL_DOMAIN`).
#
# Consumer snippets:
#   worktree setup / .cursor/environment.json install:
#     eval "$(nix run github:jmmaloney4/jackpkgs#git-bot-identity)"
#   one-shot command:
#     nix run github:jmmaloney4/jackpkgs#git-bot-identity -- --exec -- git status

name="${GROKBOT_GIT_NAME:-}"
email="${GROKBOT_GIT_EMAIL:-}"
domain="${GROKBOT_GIT_EMAIL_DOMAIN:-bots.roomofrequirement.xyz}"

usage() {
  cat <<'EOF'
Usage: git-bot-identity [--help]
       git-bot-identity [--exec --] <command> [<args>...]

Prints shell `export` lines for GROKBOT_GIT_* and GIT_AUTHOR_* / GIT_COMMITTER_*
on stdout (stderr for warnings). Does not run `git config`.

  eval "$(git-bot-identity)"

  git-bot-identity --exec -- git commit -m "message"

Environment:
  GROKBOT_GIT_NAME, GROKBOT_GIT_EMAIL — preferred identity (launch prompt).
  GROKBOT_GIT_EMAIL_DOMAIN — trailer fallback domain (default bots.roomofrequirement.xyz).
EOF
}

resolve_identity() {
  if [[ -n $name && -n $email ]]; then
    return 0
  fi

  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "git-bot-identity: warning: not a git worktree; skipping" >&2
    return 1
  fi

  local trailer
  trailer="$(git log -n 50 --pretty='%(trailers:key=Bot,valueonly)' 2>/dev/null | sed '/^$/d' | head -n1 || true)"
  if [[ -n $trailer ]]; then
    if [[ -z $name && -z $email ]]; then
      name="$trailer"
      local bare="${trailer%% (*}"
      email="${bare}@${domain}"
      echo "git-bot-identity: GROKBOT_GIT_NAME/EMAIL unset; falling back to Bot: trailer \`${trailer}\`" >&2
    else
      echo "git-bot-identity: warning: only one of GROKBOT_GIT_NAME/GROKBOT_GIT_EMAIL set; ignoring Bot: trailer \`${trailer}\`" >&2
    fi
  fi

  if [[ -z $name || -z $email ]]; then
    echo 'git-bot-identity: warning: GROKBOT_GIT_NAME and GROKBOT_GIT_EMAIL are unset, and no recent `Bot: <name> (<Title>)` trailer was found.' >&2
    echo "git-bot-identity: not exporting identity. Launch should export:" >&2
    echo "  export GROKBOT_GIT_NAME='<name> (<Title>)' GROKBOT_GIT_EMAIL='<name>@${domain}' GIT_AUTHOR_NAME=\"\$GROKBOT_GIT_NAME\" GIT_AUTHOR_EMAIL=\"\$GROKBOT_GIT_EMAIL\" GIT_COMMITTER_NAME=\"\$GROKBOT_GIT_NAME\" GIT_COMMITTER_EMAIL=\"\$GROKBOT_GIT_EMAIL\"" >&2
    return 1
  fi

  return 0
}

emit_exports() {
  printf 'export GROKBOT_GIT_NAME=%q\n' "$name"
  printf 'export GROKBOT_GIT_EMAIL=%q\n' "$email"
  printf 'export GIT_AUTHOR_NAME=%q\n' "$name"
  printf 'export GIT_AUTHOR_EMAIL=%q\n' "$email"
  printf 'export GIT_COMMITTER_NAME=%q\n' "$name"
  printf 'export GIT_COMMITTER_EMAIL=%q\n' "$email"
}

run_exec() {
  shift
  if [[ ${1:-} != -- ]]; then
    echo "git-bot-identity: --exec requires -- before command" >&2
    exit 2
  fi
  shift
  if [[ $# -eq 0 ]]; then
    echo "git-bot-identity: --exec requires a command" >&2
    exit 2
  fi
  if ! resolve_identity; then
    echo "git-bot-identity: no identity resolved; refusing --exec: $*" >&2
    exit 1
  fi
  eval "$(emit_exports)"
  exec "$@"
}

case "${1:-}" in
-h | --help)
  usage
  exit 0
  ;;
--exec)
  run_exec "$@"
  ;;
esac

if ! resolve_identity; then
  exit 0
fi

emit_exports
echo "git-bot-identity: export GROKBOT_GIT_NAME/GIT_AUTHOR_* for ${name} <${email}>" >&2
