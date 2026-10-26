# Script-behaviour tests for author-gate. Each attribute is a derivation
# that builds a throwaway git repo in the sandbox and asserts exit codes.
#
# These tests *do* see git history because they `git init` inside the
# derivation. That is the opposite of `nix flake check` against a flake
# source copy: the store path has no `.git`, which `store-copy-has-no-git`
# proves. The merge-gate therefore cannot be a pure check of the consumer
# repo; it is this CLI run in the worktree (and the pre-push hook).
{
  pkgs,
  author-gate,
}: let
  lib = pkgs.lib;
  git = pkgs.git;
  exe = lib.getExe author-gate;

  prelude = ''
    export HOME="$PWD/home"
    mkdir -p "$HOME"
    export GIT_CONFIG_NOSYSTEM=1
    export GIT_CONFIG_GLOBAL=/dev/null
    export GIT_AUTHOR_DATE="1970-01-01T00:00:00+0000"
    export GIT_COMMITTER_DATE="1970-01-01T00:00:00+0000"
    git() { ${git}/bin/git -c init.defaultBranch=main -c commit.gpgsign=false "$@"; }
    ident_jack() {
      export GIT_AUTHOR_NAME="Jack Maloney"
      export GIT_AUTHOR_EMAIL="jmmaloney4@gmail.com"
      export GIT_COMMITTER_NAME="Jack Maloney"
      export GIT_COMMITTER_EMAIL="jmmaloney4@gmail.com"
    }
    ident_bot() {
      export GIT_AUTHOR_NAME="wiesner (Shared Patterns Maintainer)"
      export GIT_AUTHOR_EMAIL="wiesner@bots.roomofrequirement.xyz"
      export GIT_COMMITTER_NAME="wiesner (Shared Patterns Maintainer)"
      export GIT_COMMITTER_EMAIL="wiesner@bots.roomofrequirement.xyz"
    }
    ident_cursor_author() {
      export GIT_AUTHOR_NAME="Cursor Agent"
      export GIT_AUTHOR_EMAIL="cursoragent@cursor.com"
      export GIT_COMMITTER_NAME="Jack Maloney"
      export GIT_COMMITTER_EMAIL="jmmaloney4@gmail.com"
    }
    ident_cursor_committer() {
      export GIT_AUTHOR_NAME="Jack Maloney"
      export GIT_AUTHOR_EMAIL="jmmaloney4@gmail.com"
      export GIT_COMMITTER_NAME="Cursor Agent"
      export GIT_COMMITTER_EMAIL="cursoragent@cursor.com"
    }
    commit_msg() {
      local body="$1"
      git commit -m "$body"
    }
    init_repo() {
      mkdir -p repo && cd repo
      git init
      ident_jack
      echo base > README
      git add README
      commit_msg "initial"
    }
    # Commits after this are merge-base(main, HEAD)..HEAD; staying on main
    # makes that range empty (HEAD *is* main).
    start_feature() {
      git checkout -b feature
    }
  '';

  mkTest = {
    name,
    body,
  }:
    pkgs.runCommand "author-gate-${name}" {
      nativeBuildInputs = [git];
    } ''
      set -euo pipefail
      ${prelude}
      ${body}
      touch "$out"
    '';
in {
  cursoragent-author-fails = mkTest {
    name = "cursoragent-author-fails";
    body = ''
      init_repo
      start_feature
      ident_cursor_author
      echo bad > f
      git add f
      commit_msg "$(printf 'agent work\n\nBot: wiesner (Shared Patterns Maintainer)\n')"
      set +e
      ${exe} --base main
      rc=$?
      set -e
      if [ "$rc" -ne 1 ]; then
        echo "expected exit 1, got $rc"
        exit 1
      fi
    '';
  };

  cursoragent-committer-fails = mkTest {
    name = "cursoragent-committer-fails";
    body = ''
      init_repo
      start_feature
      ident_cursor_committer
      echo bad > f
      git add f
      commit_msg "$(printf 'agent work\n\nBot: wiesner (Shared Patterns Maintainer)\n')"
      set +e
      ${exe} --base main
      rc=$?
      set -e
      if [ "$rc" -ne 1 ]; then
        echo "expected exit 1, got $rc"
        exit 1
      fi
      ${exe} --base main 2> err || true
      grep -q 'git rebase --exec' err
      grep -q 'cursoragent@cursor.com' err
      grep -q 'bots.roomofrequirement.xyz' err
      grep -q 'committer=' err
      if grep -q 'commiter=' err; then
        echo "gate output has typo commiter= (should be committer=)"
        cat err
        exit 1
      fi
    '';
  };

  bot-author-passes = mkTest {
    name = "bot-author-passes";
    body = ''
      init_repo
      start_feature
      ident_bot
      echo ok > f
      git add f
      commit_msg "$(printf 'bot work\n\nBot: wiesner (Shared Patterns Maintainer)\n')"
      ${exe} --base main
    '';
  };

  jack-author-passes = mkTest {
    name = "jack-author-passes";
    body = ''
      init_repo
      start_feature
      ident_jack
      echo ok > f
      git add f
      commit_msg "jack work"
      ${exe} --base main
    '';
  };

  empty-range-passes = mkTest {
    name = "empty-range-passes";
    body = ''
      init_repo
      # HEAD is main; merge-base(main, HEAD)..HEAD is empty.
      ${exe} --base main
    '';
  };

  shallow-clone-clear-error = mkTest {
    name = "shallow-clone-clear-error";
    body = ''
      mkdir origin && cd origin
      git init
      ident_jack
      echo a > README
      git add README
      commit_msg "a"
      echo b >> README
      git add README
      commit_msg "b"
      echo c >> README
      git add README
      commit_msg "c"
      git checkout -b feature
      ident_cursor_author
      echo d >> README
      git add README
      commit_msg "$(printf 'agent\n\nBot: wiesner (Shared Patterns Maintainer)\n')"
      cd ..
      git -c protocol.file.allow=always clone --depth=1 "file://$PWD/origin" shallow
      cd shallow
      git -c protocol.file.allow=always remote set-url origin "file://$PWD/../origin"
      set +e
      ${exe} --base origin/main
      rc=$?
      set -e
      if [ "$rc" -ne 2 ]; then
        echo "expected exit 2 for shallow clone, got $rc"
        exit 1
      fi
      ${exe} --base origin/main 2> err || true
      grep -qi 'shallow' err
    '';
  };

  store-copy-has-no-git = mkTest {
    name = "store-copy-has-no-git";
    body = ''
      init_repo
      ident_cursor_author
      echo bad > f
      git add f
      commit_msg "agent"
      cd ..
      mkdir copy
      # Simulate the flake source copy Nix puts in the store: tracked files,
      # no .git. A pure check running against that copy cannot see authors.
      cp -a repo/README repo/f copy/
      cd copy
      set +e
      ${exe}
      rc=$?
      set -e
      if [ "$rc" -ne 2 ]; then
        echo "expected exit 2 (not a git worktree), got $rc"
        exit 1
      fi
      ${exe} 2> err || true
      grep -q 'not a git worktree' err
      grep -q 'nix flake check' err
    '';
  };

  ident-mode-blocks-cursoragent = mkTest {
    name = "ident-mode-blocks-cursoragent";
    body = ''
      init_repo
      ident_cursor_author
      set +e
      ${exe} --mode ident
      rc=$?
      set -e
      if [ "$rc" -ne 1 ]; then
        echo "expected exit 1, got $rc"
        exit 1
      fi
      ${exe} --mode ident 2> err || true
      grep -q 'git-bot-identity' err
      grep -q 'GIT_AUTHOR_NAME' err
      grep -q -- '-c user.name' err
      grep -qi 're-commit' err
      if grep -q 'git rebase --exec' err; then
        echo "ident-mode hint must not print rebase --exec (nothing is on HEAD yet)"
        cat err
        exit 1
      fi
    '';
  };

  # New-branch pre-push: FROM_REF is 40 zeros, so the hook range is unusable.
  # The gate must fall back to merge-base and still fail on the cursoragent
  # commit in the pushed range (not exit 0).
  pre-push-all-zeros-from-ref-fails = mkTest {
    name = "pre-push-all-zeros-from-ref-fails";
    body = ''
      init_repo
      start_feature
      ident_cursor_author
      echo bad > f
      git add f
      commit_msg "$(printf 'agent work\n\nBot: wiesner (Shared Patterns Maintainer)\n')"
      export PRE_COMMIT_FROM_REF=0000000000000000000000000000000000000000
      export PRE_COMMIT_TO_REF="$(git rev-parse HEAD)"
      set +e
      ${exe} --base main
      rc=$?
      set -e
      if [ "$rc" -ne 1 ]; then
        echo "expected exit 1 for all-zeros pre-push from-ref with cursoragent commit, got $rc"
        exit 1
      fi
    '';
  };

  # Pre-push FROM_REF is a plausible sha that is not in this repo (not fetched).
  # Same fail-closed requirement as the all-zeros case.
  pre-push-unknown-from-ref-fails = mkTest {
    name = "pre-push-unknown-from-ref-fails";
    body = ''
      init_repo
      start_feature
      ident_cursor_author
      echo bad > f
      git add f
      commit_msg "$(printf 'agent work\n\nBot: wiesner (Shared Patterns Maintainer)\n')"
      export PRE_COMMIT_FROM_REF=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
      export PRE_COMMIT_TO_REF="$(git rev-parse HEAD)"
      set +e
      ${exe} --base main
      rc=$?
      set -e
      if [ "$rc" -ne 1 ]; then
        echo "expected exit 1 for unknown pre-push from-ref with cursoragent commit, got $rc"
        exit 1
      fi
    '';
  };

  ident-mode-allows-jack = mkTest {
    name = "ident-mode-allows-jack";
    body = ''
      init_repo
      ident_jack
      ${exe} --mode ident
    '';
  };

  cavins-domain-in-fix = mkTest {
    name = "cavins-domain-in-fix";
    body = ''
      init_repo
      start_feature
      ident_cursor_author
      echo bad > f
      git add f
      commit_msg "$(printf 'agent\n\nBot: grok (Cavins)\n')"
      ${exe} --base main --bot-email-domain bots.cavinsresearch.io 2> err || true
      grep -q 'bots.cavinsresearch.io' err
      # Same amend shape as the default-domain hint (git 2.55 rejects
      # --reset-author together with --author).
      grep -q 'GIT_COMMITTER_NAME' err
      grep -q -- '--author=' err
      if grep -q -- '--reset-author' err; then
        echo "Cavins fix command must not use --reset-author"
        cat err
        exit 1
      fi
    '';
  };

  # Dogfood: git 2.55 errors with
  #   fatal: options '--reset-author' and '--author' cannot be used together
  # when the printed rebase --exec is copy-pasted. Extract that command,
  # run it, and require the gate to pass on the rewritten identity.
  missing-blocked-email-value-exits-2 = mkTest {
    name = "missing-blocked-email-value-exits-2";
    body = ''
      init_repo
      set +e
      ${exe} --blocked-email 2> err
      rc=$?
      set -e
      if [ "$rc" -ne 2 ]; then
        echo "expected exit 2 for --blocked-email without value, got $rc"
        exit 1
      fi
      grep -q 'requires an argument' err
    '';
  };

  missing-mode-value-exits-2 = mkTest {
    name = "missing-mode-value-exits-2";
    body = ''
      init_repo
      set +e
      ${exe} --mode 2> err
      rc=$?
      set -e
      if [ "$rc" -ne 2 ]; then
        echo "expected exit 2 for --mode without value, got $rc"
        exit 1
      fi
      grep -q 'requires an argument' err
    '';
  };

  printed-fix-rewrites-cursoragent-identity = mkTest {
    name = "printed-fix-rewrites-cursoragent-identity";
    body = ''
      init_repo
      start_feature
      ident_cursor_author
      echo bad > f
      git add f
      commit_msg "$(printf 'agent work\n\nBot: wiesner (Shared Patterns Maintainer)\n')"
      set +e
      ${exe} --base main 2> err
      rc=$?
      set -e
      if [ "$rc" -ne 1 ]; then
        echo "expected exit 1 before rewrite, got $rc"
        cat err
        exit 1
      fi
      if grep -q -- '--reset-author' err; then
        echo "printed fix must not use --reset-author (incompatible with --author on git 2.55)"
        cat err
        exit 1
      fi
      if grep -q 'commiter=' err; then
        echo "gate output has typo commiter= (should be committer=)"
        cat err
        exit 1
      fi
      cmd=$(grep -E '^[[:space:]]*git rebase --exec' err | head -n 1)
      if [ -z "$cmd" ]; then
        echo "no git rebase --exec line in gate output"
        cat err
        exit 1
      fi
      eval "$cmd"
      ${exe} --base main
      ident=$(git log -1 --format='%an <%ae>%n%cn <%ce>')
      expected=$(printf '%s\n%s' \
        'wiesner (Shared Patterns Maintainer) <wiesner@bots.roomofrequirement.xyz>' \
        'wiesner (Shared Patterns Maintainer) <wiesner@bots.roomofrequirement.xyz>')
      if [ "$ident" != "$expected" ]; then
        echo "identity after printed fix:"
        printf '%s\n' "$ident"
        echo "expected:"
        printf '%s\n' "$expected"
        exit 1
      fi
    '';
  };
}
