# jackpkgs.repo-sync -- commit, rebase and push agent-authored edits from a
# dedicated checkout of a GitHub repo, then keep one PR open for them.
#
# NixOS (systemd service + timer) backend only. Promoted from garden's
# `services.garden-sync` (garden ADR 166; the darwin/launchd backend stays in
# garden). Renamed because nothing in it is garden-specific once the repo is a
# parameter: `repo`, `repoPath`, `branch`, `paths` and the commit identity are
# all REQUIRED options with no default (ADR-051 Decision 4 -- a repo, a branch
# and an author are identity/topology). Enabling the module without wiring them
# fails at evaluation; importing it without enabling does not.
#
# Interface (what a consumer must know, so they never read the script):
#
#   * Every `interval` seconds, as `user`, in `repoPath`: stage ONLY `paths`
#     (deletions included), commit them to `branch`, rebase onto the remote
#     `branch` and onto `baseBranch`, force-with-lease push, and open a PR from
#     `branch` to `baseBranch` if none exists.
#   * Expected states log and exit 0 rather than crash-loop the unit: the
#     checkout is not cloned yet, no token is available, a rebase conflicts
#     (aborted for manual resolution), changes outside `paths` are staged.
#   * A configured 1Password reference that cannot be read exits NON-ZERO. That
#     is a misconfiguration (rotated secret, revoked service account), not an
#     expected state, and exiting 0 would let the sync rot invisibly.
#   * `repoPath` must be cloned once, as `user`; the module does not clone.
#   * Network git goes over HTTPS with a token via a transient credential
#     helper; the checkout's own `origin` is never read or modified.
#
# Not here: the garden-specific assertion that a host's Home Manager config
# points `~/.claude/skills` at the synced checkout (it needs the HM tree),
# and any launchd support.
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.jackpkgs.repo-sync;

  homeDir =
    if cfg.homeDirectory != null
    then cfg.homeDirectory
    else "/home/${cfg.user}";

  opCfg = cfg.onePassword;
  op = lib.getExe opCfg.package;

  # GitHub token acquisition: via the 1Password service account when configured
  # (op read), else from `githubTokenEnvFile` if set and present, else the user's gh auth.
  githubTokenSetup =
    if (opCfg.tokenFile != null && opCfg.githubTokenRef != null)
    then ''
      # 1Password is explicitly configured: fail LOUDLY if the token can't be
      # read, rather than silently falling back to other auth (which could push
      # with an unintended identity) or quietly skipping the cycle.
      #
      # This is the one place the module deliberately does not "log and exit 0".
      # Everywhere else that discipline covers expected states -- an un-cloned
      # checkout, a rebase conflict, a host with no gh login yet. A configured
      # `op://` reference that cannot be read is a MISCONFIGURATION: a rotated
      # secret, a revoked service account, an unreadable agenix file. Exiting 0
      # there would let the sync rot invisibly, which is precisely the failure
      # this module exists to remove. A non-zero exit is also what the post-deploy
      # health check reads (`systemctl --failed`). It does not crash-loop: a oneshot
      # unit driven by a timer simply waits for the next tick.
      #
      # The failures are wrapped only so that our own diagnostic is guaranteed to
      # reach the log; under `set -e` a bare assignment would abort the script
      # with nothing but the tool's own stderr for context.
      if ! OP_SERVICE_ACCOUNT_TOKEN="$(cat ${escapeShellArg (toString opCfg.tokenFile)})"; then
        echo "repo-sync: cannot read the 1Password service-account token file ${escapeShellArg (toString opCfg.tokenFile)}"
        exit 1
      fi
      export OP_SERVICE_ACCOUNT_TOKEN
      if ! tok="$(${op} read ${escapeShellArg opCfg.githubTokenRef})"; then
        echo "repo-sync: op read ${escapeShellArg opCfg.githubTokenRef} failed; not falling back to other credentials"
        exit 1
      fi
      if [ -z "$tok" ]; then
        echo "repo-sync: failed to read GitHub token from 1Password"
        exit 1
      fi
      export GH_TOKEN="$tok" GITHUB_TOKEN="$tok"
    ''
    else ''
      ${optionalString (cfg.githubTokenEnvFile != null) ''
        if [ -f ${escapeShellArg cfg.githubTokenEnvFile} ]; then
          tok="$(grep -E '^GITHUB_TOKEN=' ${escapeShellArg cfg.githubTokenEnvFile} | head -1 | cut -d= -f2- || true)"
          # dotenv values are often quoted; strip one surrounding pair.
          case "$tok" in
            \"*\") tok="''${tok#\"}"; tok="''${tok%\"}" ;;
            \'*\') tok="''${tok#\'}"; tok="''${tok%\'}" ;;
          esac
          if [ -n "''${tok:-}" ]; then
            export GH_TOKEN="$tok" GITHUB_TOKEN="$tok"
          fi
        fi
      ''}
      # Last resort: the user's own gh login. `gh auth git-credential` works
      # unattended and needs no ssh agent, which matters because this runs from
      # a timer with no inbound session.
      if [ -z "''${GH_TOKEN:-}" ]; then
        tok="$(${lib.getExe pkgs.gh} auth token 2>/dev/null || true)"
        if [ -n "''${tok:-}" ]; then
          export GH_TOKEN="$tok" GITHUB_TOKEN="$tok"
        fi
      fi
    '';

  syncScript = pkgs.writeShellApplication {
    name = "repo-sync-as-${cfg.user}";
    # findutils for the flatten step's `find`. coreutils does NOT provide it,
    # and writeShellApplication PREPENDS runtimeInputs to $PATH rather than
    # replacing it -- so without this the flatten resolves `find` from whatever
    # ambient PATH the supervisor happens to supply (/run/current-system/sw/bin
    # on systemd). It would work by accident, which is exactly the
    # dependency-on-the-environment writeShellApplication exists to remove.
    #
    # git-annex: a synced repo may declare annex-filtered paths
    # (.gitattributes). Once anyone runs `git annex init` in the checkout,
    # `git add` spawns `git-annex filter-process`; without it on PATH that exits
    # 128 and `set -e` stops the sync silently (observed in a real consumer). The binary is large
    # (Haskell), but a PATH dependency on ambient state is the worse trade.
    runtimeInputs = with pkgs; [git gh openssh coreutils gnugrep findutils git-annex];
    text = ''
      repo=${escapeShellArg cfg.repoPath}
      branch=${escapeShellArg cfg.branch}
      base=${escapeShellArg cfg.baseBranch}

      if ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
        echo "repo-sync: $repo is not a git checkout yet; skipping."
        echo "  Bootstrap it once as ${cfg.user}:"
        echo "    git clone git@github.com:${cfg.repo}.git \"$repo\""
        echo "    git -C \"$repo\" switch -c $branch || git -C \"$repo\" switch $branch"
        exit 0
      fi
      cd "$repo"

      # Acquire a GitHub token (1Password service account / .env / gh auth).
      ${githubTokenSetup}

      if [ -z "''${GH_TOKEN:-}" ]; then
        echo "repo-sync: no GitHub token available; skipping this cycle."
        exit 0
      fi

      # Talk to GitHub over HTTPS with the token supplied through a transient
      # credential helper. The checkout's own `origin` is an SSH URL for humans
      # and this runs from a timer with no agent, so all network git goes
      # through a throwaway remote defined entirely on the command line. The
      # helper keeps the token out of argv, out of the remote URL, and out of
      # persisted config.
      # shellcheck disable=SC2016 # NOT expanding $GH_TOKEN here is the point:
      # git passes this string to a shell of its own, so the token is resolved
      # in that child and never appears in this process's argv.
      credHelper='!f() { echo username=x-access-token; echo "password=$GH_TOKEN"; }; f'
      # A bare `-c credential.helper=...` APPENDS to whatever the user's
      # ~/.gitconfig already configures, and git tries each in order. A user
      # config that sets `gh auth git-credential` would be consulted first and
      # can fail noisily. The empty `-c credential.helper=` resets the
      # list, so only ours is used and behaviour does not depend on user config.
      #
      # The remote is a NEW name rather than an override of `origin`, and that
      # is load-bearing: `remote.<name>.url` is a MULTI-valued key, so
      # `-c remote.origin.url=...` appends rather than replaces and the
      # checkout's own SSH URL still wins. A name absent from the checkout's
      # config has no competing value.
      #
      # It is also a named remote rather than a bare URL argument, which matters
      # in two more places:
      #
      #   * a bare-URL fetch updates only FETCH_HEAD, never
      #     `refs/remotes/origin/*`, so step 2's "incorporate the remote branch"
      #     rebase would run against a permanently stale `origin/$branch` and
      #     silently no-op.
      #   * `git push --force-with-lease` with no explicit expected value
      #     resolves that value through the remote's fetch refspec. A bare URL
      #     is an anonymous remote with no refspec, so the lease degrades to the
      #     NULL oid ("this branch must not exist") and every push to an
      #     already-existing branch is rejected with `stale info` -- the sync
      #     would never push again. Verified against git 2.54.0.
      #
      # The refspec therefore maps into `refs/remotes/origin/*`: the rebase
      # steps and the push lease below both read those refs, exactly as they did
      # when this fetched over `origin` directly.
      #
      # GIT_TERMINAL_PROMPT=0 is the unattended-safety property: without it a
      # credential failure can block on an interactive prompt forever inside a
      # timer-driven unit.
      export GIT_TERMINAL_PROMPT=0
      gitauth() {
        git -c credential.helper= -c credential.helper="$credHelper" \
          -c remote.repo-sync-https.url=${escapeShellArg "https://github.com/${cfg.repo}.git"} \
          -c 'remote.repo-sync-https.fetch=+refs/heads/*:refs/remotes/origin/*' \
          "$@"
      }
      gitpush() { gitauth push repo-sync-https "$@"; }
      gitfetch() { gitauth fetch repo-sync-https "$@"; }

      # Fetch refs up front so branch creation and rebases have a basis. This
      # also refreshes refs/remotes/origin/{$base,$branch}, which the rebase
      # steps and the push lease below both read.
      gitfetch "$base" "$branch" 2>/dev/null || gitfetch "$base" || {
        echo "repo-sync: fetch failed; skipping this cycle."
        exit 0
      }

      # Ensure we are on the dedicated branch. When it must be created, base it
      # on the remote branch if present, else origin/$base — never inherit
      # unrelated commits from whatever the clone happened to have checked out.
      current="$(git rev-parse --abbrev-ref HEAD)"
      if [ "$current" != "$branch" ]; then
        if git show-ref --verify --quiet "refs/heads/$branch"; then
          git switch "$branch"
        elif git show-ref --verify --quiet "refs/remotes/origin/$branch"; then
          git switch -c "$branch" "origin/$branch"
        else
          git switch -c "$branch" "origin/$base"
        fi
      fi

      # 0. Flatten any skill the agent filed under a category directory.
      #
      # Claude Code discovers skills at exactly <dir>/<name>/SKILL.md -- ONE
      # level, no deeper -- so a skill written to <dir>/<category>/<name>/ is
      # invisible to it. Some agents file new skills under a
      # category by default, so a hand-flattened library drifts straight back.
      # Doing it here means the library cannot regress through the one path
      # that writes to it unattended.
      #
      # Opt-in via `flattenSkillsDir` (and required to sit inside `paths`): a
      # daemon that does not sync a skills tree has no business rewriting it.
      # The `-d` test covers the tree simply not existing yet.
      #
      # Deliberately conservative:
      #   - plain `mv` of the whole skill directory, so references/, scripts/
      #     and templates/ travel with it. Not `git mv`: these skills are
      #     usually brand new and untracked, which `git mv` refuses.
      #   - NEVER across an existing flat skill. A collision means two skills
      #     share a name; silently overwriting one would destroy work, so it is
      #     logged and left nested for a human.
      #   - dot-directories are skipped (e.g. an `.archive/` that deliberately
      #     holds retired skills nested; flattening would resurrect them).
      #   - a directory that holds its own SKILL.md is a skill, not a category,
      #     so its subdirectories are left alone (see the guard below).
      ${lib.optionalString (cfg.flattenSkillsDir != null) ''
        sroot=${escapeShellArg cfg.flattenSkillsDir}
        if [ -d "$sroot" ]; then
          find "$sroot" -mindepth 3 -maxdepth 3 -name SKILL.md -print | while read -r skillfile; do
            skilldir=$(dirname "$skillfile")
            category=$(dirname "$skilldir")
            name=$(basename "$skilldir")
            case "$(basename "$category")" in
              .*) continue ;;
            esac
            # A directory holding SKILL.md is a SKILL, not a category -- so its
            # subdirectories are that skill's own payload, not nested skills.
            # Without this guard a flat skill that bundles e.g. templates/SKILL.md
            # as an example matches the depth-3 find and gets its templates/
            # torn out to $sroot/templates/, destroying the very thing this
            # flatten exists to protect.
            if [ -e "$category/SKILL.md" ]; then
              continue
            fi
            if [ -e "$sroot/$name" ]; then
              echo "repo-sync: name collision, leaving nested: $skilldir ($sroot/$name already exists)"
              continue
            fi
            mv "$skilldir" "$sroot/$name"
            echo "repo-sync: flattened $skilldir -> $sroot/$name"
            # Drop the category dir once its last skill leaves; ignore failure, it
            # simply means other skills (or a collision left behind) remain.
            rmdir "$category" 2>/dev/null || true
          done
        fi

      ''}

      # 1. Capture agent-authored edits. Only the configured paths are ever
      #    staged, so unrelated working-tree changes are never committed.
      #
      #    A path is staged when it exists OR when it is still tracked, which is
      #    what carries DELETIONS through. Curating means removing files,
      #    and an existence-only guard would drop a wholly-removed path on the
      #    floor forever: the deletion never reaches the branch, and the next
      #    rebase brings the file back.
      staged=0
      # shellcheck disable=SC2043 # the list is generated from cfg.paths and is
      # a single element on hosts that sync only one path.
      for p in ${escapeShellArgs cfg.paths}; do
        if [ -e "$p" ] || [ -n "$(git ls-files -- "$p")" ]; then
          git add -A -- "$p"
          staged=1
        fi
      done
      if [ "$staged" -eq 0 ]; then
        echo "repo-sync: none of the configured paths exist in $repo; nothing to stage."
      fi

      # "Only the configured paths are ever staged" is true of what this script
      # stages, but the commit below takes the whole index -- so anything a
      # human left staged in the checkout would ride along into a PR against
      # $base. Refuse to commit in that case and say so plainly: the alternative
      # is publishing someone else's work under the daemon's identity, and the
      # rebase that follows would fail anyway with a far less obvious message
      # ("cannot rebase: Your index contains uncommitted changes").
      if ! git diff --cached --quiet -- . ${escapeShellArgs (map (p: ":(exclude)${p}") cfg.paths)}; then
        echo "repo-sync: changes outside the configured paths are staged in $repo; leaving them alone and skipping this cycle."
        git diff --cached --name-only -- . ${escapeShellArgs (map (p: ":(exclude)${p}") cfg.paths)} |
          while IFS= read -r f; do echo "  staged: $f"; done
        exit 0
      fi

      # Scope the "is there anything to commit?" test to the configured paths
      # for the same reason.
      if ! git diff --cached --quiet -- ${escapeShellArgs cfg.paths}; then
        # No commit signing: this runs as a daemon with no forwarded SSH agent,
        # and signByDefault is force-enabled on darwin. Without gpgsign=false the
        # commit would try op-ssh-sign / ssh-keygen with no key available and
        # abort the sync (set -e), stranding agent edits.
        git -c commit.gpgsign=false \
          -c user.name=${escapeShellArg cfg.commitAuthor.name} \
          -c user.email=${escapeShellArg cfg.commitAuthor.email} \
          commit -m ${escapeShellArg cfg.commitMessage}
      fi

      # 2. Incorporate the remote branch (another run / a manual fix) then
      #    upstream $base before pushing.
      if git show-ref --verify --quiet "refs/remotes/origin/$branch"; then
        if ! git rebase "origin/$branch"; then
          echo "repo-sync: branch rebase conflict; aborting for manual resolution."
          git rebase --abort || true
          exit 0
        fi
      fi
      if ! git rebase "origin/$base"; then
        echo "repo-sync: $base rebase conflict; aborting for manual resolution."
        git rebase --abort || true
        exit 0
      fi

      # 3. Push the branch (no-op if nothing changed).
      gitpush --force-with-lease "HEAD:refs/heads/$branch"

      # 4. Ensure a PR exists.
      if ! gh pr view "$branch" --repo ${escapeShellArg cfg.repo} >/dev/null 2>&1; then
        gh pr create --repo ${escapeShellArg cfg.repo} --base "$base" --head "$branch" \
          --title ${escapeShellArg cfg.pullRequest.title} \
          --body ${escapeShellArg cfg.pullRequest.body} \
          || echo "repo-sync: gh pr create failed (no changes vs $base?)."
      fi
    '';
  };

  wrapper = pkgs.writeShellScript "repo-sync-wrapper-${cfg.user}" ''
    export HOME=${escapeShellArg homeDir}
    exec ${lib.getExe syncScript}
  '';
in {
  options.jackpkgs.repo-sync = {
    enable = mkEnableOption "repo sync (commit/push agent-authored edits from a dedicated checkout and keep a PR open)";

    user = mkOption {
      type = types.str;
      example = "alice";
      description = ''
        System user that owns the checkout and runs the sync (systemd `User=`).
        Required when enabled: no default (ADR-051 Decision 4).
      '';
    };

    homeDirectory = mkOption {
      type = types.nullOr types.str;
      default = null;
      defaultText = literalExpression ''"/home/''${user}"'';
      description = "HOME for the sync process, so git and gh find the user's config.";
    };

    repo = mkOption {
      type = types.strMatching "[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+";
      example = "my-org/my-repo";
      description = ''
        `owner/name` of the GitHub repository: used for the HTTPS push URL, the
        PR, and the bootstrap hint. Required when enabled: no default, so the
        module encodes no particular repository. The format is checked by the
        type, so a URL or a `.git` suffix is refused at evaluation.
      '';
    };

    repoPath = mkOption {
      type = types.strMatching "/.+";
      example = "/home/alice/checkout";
      description = ''
        Absolute path to the checkout whose `paths` are synced. Must be cloned
        as `user` (one-time bootstrap; an un-cloned path logs a hint and exits 0).
        Required when enabled.
      '';
    };

    branch = mkOption {
      type = types.strMatching "[A-Za-z0-9._][A-Za-z0-9._/-]*";
      example = "agent-sync";
      description = ''
        Long-lived branch that agent-authored changes are committed and pushed
        to. Required when enabled: no default, because two hosts syncing one
        repo must not collide on an implicit branch name. Must differ from
        `baseBranch`.
      '';
    };

    baseBranch = mkOption {
      type = types.strMatching "[A-Za-z0-9._][A-Za-z0-9._/-]*";
      default = "main";
      description = "Branch the sync branch is rebased onto and the PR targets.";
    };

    paths = mkOption {
      # nonEmptyListOf, not listOf: an unset `listOf` defaults to [] and would
      # make "commit nothing" a silently expressible state (ADR-051 Decision 3).
      type = types.nonEmptyListOf (types.strMatching "[^/].*");
      example = ["skills" "notes/MEMORY.md"];
      description = ''
        Repo-relative paths to stage. A path that does not exist (and is not
        tracked) is skipped. Nothing outside this list is ever committed, so
        unrelated working-tree changes in the checkout are safe. Required when
        enabled; absolute paths and `..` components are refused.
      '';
    };

    flattenSkillsDir = mkOption {
      type = types.nullOr (types.strMatching "[^/].*");
      default = null;
      example = "skills";
      description = ''
        Repo-relative directory holding agent skills at
        `<dir>/<name>/SKILL.md`. When set, each cycle first moves any skill
        filed one category deeper (`<dir>/<category>/<name>/SKILL.md`) up to
        `<dir>/<name>`, because Claude Code discovers skills at exactly one
        level. Never overwrites an existing skill and skips dot-directories.
        Must be one of (or inside) `paths`. `null` (default) leaves the tree alone.
      '';
    };

    commitMessage = mkOption {
      type = types.str;
      default = "chore: agent updates (auto)";
      description = "Commit message for auto-generated commits.";
    };

    commitAuthor = {
      name = mkOption {
        type = types.str;
        example = "Sync Bot";
        description = "git author/committer name for auto-generated commits. Required when enabled: identity, no default.";
      };

      email = mkOption {
        type = types.str;
        example = "sync-bot@example.com";
        description = "git author/committer email for auto-generated commits. Required when enabled: identity, no default.";
      };
    };

    pullRequest = {
      title = mkOption {
        type = types.str;
        default = "chore: agent updates";
        description = "Title of the long-lived PR this daemon keeps open.";
      };

      body = mkOption {
        type = types.str;
        default = "Automated sync of agent-authored edits. Auto-updated by jackpkgs.repo-sync.";
        description = "Body of the long-lived PR this daemon keeps open.";
      };
    };

    onePassword = {
      package = mkOption {
        type = types.package;
        default = pkgs._1password-cli;
        defaultText = literalExpression "pkgs._1password-cli";
        description = ''
          The `op` CLI. Only evaluated when `tokenFile`/`githubTokenRef` are
          set. The default is unfree, so a consumer using 1Password must allow
          it (`nixpkgs.config.allowUnfreePredicate`) or supply another package;
          a host that never configures 1Password never evaluates it.
        '';
      };

      tokenFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          Path to a 1Password service-account token file. When set alongside
          githubTokenRef, the sync job exports OP_SERVICE_ACCOUNT_TOKEN and
          `op read`s the GitHub token instead of using `githubTokenEnvFile` / gh
          auth. Using this pulls `onePassword.package` into the closure.
        '';
      };

      githubTokenRef = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "op://Private/github-token/credential";
        description = "1Password op:// reference for the GitHub token used to push + open the PR.";
      };
    };

    githubTokenEnvFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/home/alice/.agent/.env";
      description = ''
        Optional env file read for a `GITHUB_TOKEN=` line when 1Password is not
        configured. If unset or absent the sync falls back to the user's own
        `gh auth token`.
      '';
    };

    interval = mkOption {
      type = types.ints.positive;
      default = 1800;
      description = "Seconds between sync runs.";
    };

    script = mkOption {
      type = types.package;
      internal = true;
      readOnly = true;
      description = ''
        The resolved sync program. Internal: exists so tests can inspect the
        generated script text without building anything.
      '';
    };
  };

  config = mkIf cfg.enable {
    jackpkgs.repo-sync.script = syncScript;

    assertions = [
      {
        assertion = (opCfg.tokenFile != null) == (opCfg.githubTokenRef != null);
        message = "jackpkgs.repo-sync.onePassword.tokenFile and githubTokenRef must be set together (or both null).";
      }
      {
        assertion = cfg.branch != cfg.baseBranch;
        message = "jackpkgs.repo-sync.branch must differ from baseBranch (${cfg.baseBranch}); the sync would rebase and PR a branch onto itself.";
      }
      {
        assertion = all (p: !(elem ".." (splitString "/" p))) (cfg.paths ++ optional (cfg.flattenSkillsDir != null) cfg.flattenSkillsDir);
        message = "jackpkgs.repo-sync.paths and flattenSkillsDir must not contain `..` components.";
      }
      {
        assertion = cfg.flattenSkillsDir == null || any (p: p == cfg.flattenSkillsDir || hasPrefix "${p}/" cfg.flattenSkillsDir) cfg.paths;
        message = "jackpkgs.repo-sync.flattenSkillsDir must be one of (or inside) `paths`; otherwise the moves would never be committed.";
      }
    ];

    systemd.services.repo-sync = {
      description = "Sync agent-authored edits in the ${cfg.repo} checkout";
      after = ["network-online.target"];
      wants = ["network-online.target"];
      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        # A stuck git or gh call must not pin the unit forever. Every handled
        # condition in the script exits 0, so hitting this timeout means
        # something genuinely hung rather than a condition we anticipated.
        TimeoutStartSec = "10m";
        ExecStart = "${wrapper}";
      };
    };

    systemd.timers.repo-sync = {
      description = "Periodic ${cfg.repo} checkout sync";
      wantedBy = ["timers.target"];
      timerConfig = {
        # OnBootSec is what catches up after downtime: OnUnitActiveSec is
        # relative to the last activation and never fires on its own after a
        # cold boot. `Persistent=` is deliberately NOT set -- systemd.timer(5)
        # says it only has an effect on OnCalendar= timers, so it would be an
        # inert option that reads as if catch-up were configured.
        OnBootSec = "5m";
        OnUnitActiveSec = "${toString cfg.interval}s";
        # Spread load so several hosts do not hit GitHub on the same second.
        RandomizedDelaySec = "2m";
      };
    };
  };
}
