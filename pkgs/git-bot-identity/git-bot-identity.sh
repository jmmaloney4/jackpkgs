# git-bot-identity — persist the launching bot's git identity in the repo.
#
# Env var convention (launching bot MUST set these on the cloud-agent launch):
#
#   GROKBOT_GIT_NAME   Display name, e.g. `wiesner (Shared Patterns Maintainer)`.
#                      Matchers elsewhere key on the bare name before ` (`;
#                      keep the ` (<Title>)` suffix.
#   GROKBOT_GIT_EMAIL  Email, e.g. `wiesner@bots.roomofrequirement.xyz`.
#                      Cavins bots: `<name>@bots.cavinsresearch.io`.
#
# Launching-bot one-liner (the one line to put in the cloud-agent launch):
#
#   export GROKBOT_GIT_NAME='wiesner (Shared Patterns Maintainer)' GROKBOT_GIT_EMAIL='wiesner@bots.roomofrequirement.xyz' GIT_AUTHOR_NAME="$GROKBOT_GIT_NAME" GIT_AUTHOR_EMAIL="$GROKBOT_GIT_EMAIL" GIT_COMMITTER_NAME="$GROKBOT_GIT_NAME" GIT_COMMITTER_EMAIL="$GROKBOT_GIT_EMAIL"
#
# Assessment of GIT_AUTHOR_* / GIT_COMMITTER_*: git honors them for any
# `git commit` that inherits the environment, which is enough for a single
# carefully-wrapped process. It is NOT enough for Cursor cloud agents:
# they spawn many git subprocesses, and the VM gitconfig often defaults to
# `Cursor Agent <cursoragent@cursor.com>` when those variables are unset.
# This script writes repo-local `user.name` / `user.email` so identity
# survives without the agent remembering to export anything.
#
# Consumer snippets:
#   .cursor/environment.json install (append):
#     nix run github:jmmaloney4/jackpkgs#git-bot-identity
#   worktree setup script:
#     nix run github:jmmaloney4/jackpkgs#git-bot-identity

name="${GROKBOT_GIT_NAME:-}"
email="${GROKBOT_GIT_EMAIL:-}"
domain="${GROKBOT_GIT_EMAIL_DOMAIN:-bots.roomofrequirement.xyz}"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "git-bot-identity: warning: not a git worktree; skipping" >&2
  exit 0
fi

if [[ -z $name || -z $email ]]; then
  trailer="$(git log -n 50 --pretty='%(trailers:key=Bot,valueonly)' 2>/dev/null | sed '/^$/d' | head -n1 || true)"
  if [[ -n $trailer ]]; then
    if [[ -z $name ]]; then
      name="$trailer"
    fi
    if [[ -z $email ]]; then
      bare="${trailer%% (*}"
      email="${bare}@${domain}"
    fi
    echo "git-bot-identity: GROKBOT_GIT_NAME/EMAIL unset; falling back to Bot: trailer \`${trailer}\`" >&2
  fi
fi

if [[ -z $name || -z $email ]]; then
  echo 'git-bot-identity: warning: GROKBOT_GIT_NAME and GROKBOT_GIT_EMAIL are unset, and no recent `Bot: <name> (<Title>)` trailer was found.' >&2
  echo "git-bot-identity: not changing git user.name / user.email. Launch should export:" >&2
  echo "  export GROKBOT_GIT_NAME='<name> (<Title>)' GROKBOT_GIT_EMAIL='<name>@${domain}' GIT_AUTHOR_NAME=\"\$GROKBOT_GIT_NAME\" GIT_AUTHOR_EMAIL=\"\$GROKBOT_GIT_EMAIL\" GIT_COMMITTER_NAME=\"\$GROKBOT_GIT_NAME\" GIT_COMMITTER_EMAIL=\"\$GROKBOT_GIT_EMAIL\"" >&2
  exit 0
fi

git config --local user.name "$name"
git config --local user.email "$email"
echo "git-bot-identity: set user.name=${name} user.email=${email}"
