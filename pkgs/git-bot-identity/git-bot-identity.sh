# git-bot-identity — print shell exports for the launching bot's git identity.
#
# Never writes `git config --local user.*`. Worktrees share one `.git/config`;
# repo-local identity would leak to Jack's commits. Set per-process env instead.
#
# Requires explicit env (no git-history inference):
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
# Consumer snippets:
#   worktree setup / .cursor/environment.json install:
#     eval "$(nix run github:jmmaloney4/jackpkgs#git-bot-identity)"
#   one-shot command:
#     nix run github:jmmaloney4/jackpkgs#git-bot-identity -- --exec -- git status

name="${GROKBOT_GIT_NAME:-}"
email="${GROKBOT_GIT_EMAIL:-}"

usage() {
  cat <<'EOF'
Usage: git-bot-identity [--help]
       git-bot-identity [--exec --] <command> [<args>...]

Prints shell `export` lines for GROKBOT_GIT_* and GIT_AUTHOR_* / GIT_COMMITTER_*
on stdout (messages on stderr). Does not run `git config`.

  eval "$(git-bot-identity)"

  git-bot-identity --exec -- git commit -m "message"

Environment (required):
  GROKBOT_GIT_NAME, GROKBOT_GIT_EMAIL — bot identity from the launch environment.
  Both must be set; there is no fallback from git history or Bot: trailers.

Exit status:
  0 — identity resolved; default mode printed exports on stdout.
  1 — identity could not be resolved (--exec does not run the command).
  2 — invalid usage (--exec missing `--` or command).
EOF
}

resolve_identity() {
  if [[ -n $name && -n $email ]]; then
    return 0
  fi

  if [[ -n $name || -n $email ]]; then
    echo 'git-bot-identity: error: set both GROKBOT_GIT_NAME and GROKBOT_GIT_EMAIL (only one is set)' >&2
  else
    echo 'git-bot-identity: error: GROKBOT_GIT_NAME and GROKBOT_GIT_EMAIL are required (no Bot: trailer fallback)' >&2
  fi
  echo "git-bot-identity: export before eval, e.g.:" >&2
  echo "  export GROKBOT_GIT_NAME='<name> (<Title>)' GROKBOT_GIT_EMAIL='<name>@bots.roomofrequirement.xyz'" >&2
  return 1
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
    echo "git-bot-identity: refusing --exec (identity unresolved): $*" >&2
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
  exit 1
fi

emit_exports
echo "git-bot-identity: export GROKBOT_GIT_NAME/GIT_AUTHOR_* for ${name} <${email}>" >&2
