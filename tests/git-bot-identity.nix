{
  pkgs,
  git-bot-identity,
}: let
  lib = pkgs.lib;
  git = pkgs.git;
  exe = lib.getExe git-bot-identity;

  prelude = ''
    export HOME="$PWD/home"
    mkdir -p "$HOME"
    export GIT_CONFIG_NOSYSTEM=1
    export GIT_CONFIG_GLOBAL=/dev/null
    git() { ${git}/bin/git -c init.defaultBranch=main -c commit.gpgsign=false "$@"; }
  '';

  mkTest = {
    name,
    body,
  }:
    pkgs.runCommand "git-bot-identity-${name}" {
      nativeBuildInputs = [git];
    } ''
      set -euo pipefail
      ${prelude}
      ${body}
      touch "$out"
    '';
in {
  env-vars-set-config = mkTest {
    name = "env-vars-set-config";
    body = ''
      git init repo && cd repo
      export GROKBOT_GIT_NAME="wiesner (Shared Patterns Maintainer)"
      export GROKBOT_GIT_EMAIL="wiesner@bots.roomofrequirement.xyz"
      ${exe}
      test "$(git config --local user.name)" = "wiesner (Shared Patterns Maintainer)"
      test "$(git config --local user.email)" = "wiesner@bots.roomofrequirement.xyz"
    '';
  };

  fallback-from-bot-trailer = mkTest {
    name = "fallback-from-bot-trailer";
    body = ''
      git init repo && cd repo
      export GIT_AUTHOR_NAME="Cursor Agent"
      export GIT_AUTHOR_EMAIL="cursoragent@cursor.com"
      export GIT_COMMITTER_NAME="Cursor Agent"
      export GIT_COMMITTER_EMAIL="cursoragent@cursor.com"
      echo x > f
      git add f
      git commit -m "$(printf 'work\n\nBot: wiesner (Shared Patterns Maintainer)\n')"
      unset GROKBOT_GIT_NAME GROKBOT_GIT_EMAIL || true
      ${exe}
      test "$(git config --local user.name)" = "wiesner (Shared Patterns Maintainer)"
      test "$(git config --local user.email)" = "wiesner@bots.roomofrequirement.xyz"
    '';
  };

  warning-when-nothing = mkTest {
    name = "warning-when-nothing";
    body = ''
      git init repo && cd repo
      export GIT_AUTHOR_NAME="Jack Maloney"
      export GIT_AUTHOR_EMAIL="jmmaloney4@gmail.com"
      export GIT_COMMITTER_NAME="Jack Maloney"
      export GIT_COMMITTER_EMAIL="jmmaloney4@gmail.com"
      echo x > f
      git add f
      git commit -m "jack"
      unset GROKBOT_GIT_NAME GROKBOT_GIT_EMAIL || true
      ${exe} > out 2> err
      grep -q 'warning' err
      # must not invent an identity
      if git config --local --get user.name >/dev/null; then
        echo "did not expect user.name to be set"
        exit 1
      fi
    '';
  };

  skip-outside-git = mkTest {
    name = "skip-outside-git";
    body = ''
      mkdir notgit && cd notgit
      ${exe} 2> err
      grep -q 'warning' err
    '';
  };
}
