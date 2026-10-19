# jackpkgs.claude-managed-settings — Claude Code's file-based managed-settings
# layer, installed system-wide at /etc/claude-code/ (ADR-051 fleet glue).
#
# Promoted from garden `nixfiles/modules/{common,nixos}/claude-managed-settings.nix`
# (garden ADR 187; garden#2074 Part B). NixOS only: the macOS backend
# (/Library/Application Support/ClaudeCode/) stays in garden with the rest of
# its darwin tree (ADR-051 Decision 5, amended 2026-09-25).
#
# What it is: a system-level settings file that Claude Code READS but never
# writes, so the functional slice of its config (the message-timestamps hooks,
# the statusline pointer, static keys) cannot drift per host. Everything else
# (model, theme, allowlists) stays in the per-user ~/.claude/settings.json.
# Hooks merge across settings levels and a handler defined twice runs once, so
# stale user-level registrations are redundant but harmless.
#
# Interface: `enable`, plus two payload overrides, both with shipped defaults:
#
#   * `settingsFile`      — the managed-settings.json to install
#   * `statuslineSource`  — the statusline script it points at
#
# The shipped defaults (./claude-managed-settings/) are a vendored copy
# of garden's payload (NOT policy-neutral: it sets permissions.defaultMode "auto"
# and skipAutoPermissionPrompt, see README): garden's own `autoMode` allowlist entry (a Nous Portal
# distillation pipeline) is deliberately not included. A consumer that wants its
# own payload points the options at its own files; garden is expected to do so,
# which keeps garden's file the single source of truth for garden.
# managed-settings.json must reference `/etc/claude-code/statusline-command.sh`
# and `/etc/claude-code/hooks/message-timestamps/*.sh`, the paths this module
# installs.
#
# Hard constraint: INVALID JSON in a managed settings file makes Claude Code
# refuse to start (claude.ai-credentialed sessions exit at startup). The file is
# therefore parsed with `jq` at BUILD time, so a syntax error fails the rebuild
# instead of bricking every session on the next switch. This is a validity
# gate, not a content gate.
#
# Deliberately system-level rather than home-manager: the location is a machine
# path, so the layer applies to every user on the host, and the payloads ship
# under /etc/claude-code/ rather than pointing into any user's $HOME. The one
# runtime dependency not shipped is `jq` on the invoking user's PATH; without
# it the hooks no-op with a one-time notice by their own design.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.jackpkgs.claude-managed-settings;

  # zoharbabin/claude-code-message-timestamps, pinned. Upstream ships this as
  # a Claude Code *plugin* (`claude plugin marketplace add ...`), which we
  # deliberately do NOT use: the plugin manager git-clones into
  # ~/.claude/plugins/marketplaces/<name> and keeps it updated behind our
  # back. These are hooks -- they execute shell on every prompt submit and
  # every message display -- so an unpinned auto-updating third-party clone on
  # that path is the wrong trade. Pinning a reviewed rev here makes the
  # deployed bytes reproducible and identical on every host.
  #
  # Only hooks/scripts is extracted: the upstream tree is 484K, 424K of which
  # is a demo gif and social-preview png. Linking the fetched src directly
  # would drag all of it into every generation -- the same closure-bloat
  # concern the CLAUDE.md entry documents.
  #
  # Two build-time gates, because a pinned rev fixes WHICH bytes ship but not
  # WHAT they do, and the bytes are not visible in the diff that adds them:
  #
  #  1. `bash -n` -- a syntax error in code that runs on every prompt should
  #     fail the rebuild, not fail silently at runtime (these hooks are
  #     written to degrade quietly, e.g. `command -v jq || exit 0`).
  #
  #  2. a construct denylist. Two separate statements, kept distinct on
  #     purpose because conflating them is how a gate gets over-trusted:
  #
  #     AUDITED (true of v1.3.0, established by reading all 142 lines): no
  #     network calls, no `eval`, no writes. The only externals are
  #     `command -v`, `date`, `jq`, `printf`, `tr`, `dirname`.
  #
  #     ENFORCED (what the build actually checks): the network, exec,
  #     interpreter and write primitives named in `forbidden` below. If a
  #     bump legitimately needs one, the build failure is the prompt to
  #     re-audit and amend the list deliberately.
  #
  #     Best-effort defence in depth, NOT a hard invariant -- do not read it
  #     as one. It is a substring denylist over shell source, so it does not
  #     defend against obfuscation (`$'\x63url'`, variable-assembled command
  #     names, a payload fetched by something on the list's blind side), it
  #     does not catch plain shell redirection (`> file`), and it cannot
  #     enumerate every exfil primitive. The pinned rev+hash remains the
  #     PRIMARY control: it is what fixes the bytes that actually ship. The
  #     denylist only raises the floor for future bumps.
  #
  # Worth recording precisely, because it bounds the blast radius: the
  # UserPromptSubmit hook never reads stdin at all (it calls `jq -n`), so
  # prompt text -- the thing most likely to contain a pasted secret -- does
  # not flow through this code. Only MessageDisplay reads stdin, reformatting
  # the assistant delta locally and writing it straight back to stdout.
  claude-message-timestamps = pkgs.runCommand "claude-message-timestamps-1.3.0" {} ''
        cp -R ${pkgs.fetchFromGitHub {
      owner = "zoharbabin";
      repo = "claude-code-message-timestamps";
      # v1.3.0
      rev = "3ca69cfe8530d4afa772d6615b6543982b0bab1f";
      hash = "sha256-/6ucWvvjAmixnXg9y70VFkxLH49+L40I9Ef5gGXPNOo=";
    }}/hooks/scripts $out
        chmod -R u+w $out

        # Assert the shipped file set is exactly what was audited, BEFORE the
        # content gates run. Without this the gates below are only as good as
        # their file filter: `cp -R` ships the whole tree, so a future bump that
        # adds a helper or drops a `.sh` suffix would sail past an `-name '*.sh'`
        # scan untouched. Any add, removal or rename fails the build, which is
        # the intended "re-audit me" signal rather than a silent pass.
        expected='dependency-check.sh
    lib/resolve-tz.sh
    timestamp-context.sh
    timestamp-display.sh'
        actual="$(cd $out && find . -type f | sed 's|^\./||' | LC_ALL=C sort)"
        if [ "$actual" != "$(printf '%s\n' "$expected" | LC_ALL=C sort)" ]; then
          echo "claude-message-timestamps: shipped file set differs from the audited set." >&2
          echo "--- expected ---" >&2; printf '%s\n' "$expected" | LC_ALL=C sort >&2
          echo "--- actual ---" >&2;   printf '%s\n' "$actual" | LC_ALL=C sort >&2
          exit 1
        fi

        # Every file, not just *.sh -- the allowlist above already guarantees they
        # are all shell, and filtering by extension is exactly the hole being
        # closed.
        find $out -type f -print0 | xargs -0 -n1 ${lib.getExe pkgs.bash} -n

        # Scans the file RAW -- deliberately not comment-stripped. An earlier
        # version ran `sed 's/#.*$//'` first so prose could not trip the check,
        # but sed deletes from the first `#` regardless of quoting, so
        # `echo "tag #1"; curl https://evil` slipped through with the curl
        # removed. For a security gate a false positive is cheap (amend the list)
        # and a false negative is not, so the stripping is gone. Verified the
        # pinned scripts contain no denylisted word anywhere, comments included,
        # so raw scanning costs nothing today.
        #
        # Package managers (brew/apt-get/winget) and `install` are deliberately
        # ABSENT, same root cause: upstream's dependency-check.sh names them in
        # its user-facing "brew install jq / apt-get install jq" string, so they
        # false-positive on the real scripts. Every other write primitive below
        # was checked against the pinned scripts before being added.
        # `env` is deliberately ABSENT despite being a real exec primitive:
        # every script opens with `#!/usr/bin/env bash`, so it false-positives
        # on all four. Checked, not assumed -- as with `install` and the
        # package managers above, each candidate was grepped against the pinned
        # scripts before being added, and `env` was the only one of
        # env/xargs/sed/awk/git/find that hit.
        forbidden='(^|[^[:alnum:]_])(eval|exec|xargs|sed|awk|git|find|curl|wget|ssh|scp|nc|telnet|base64|xxd|openssl|osascript|python3?|perl|ruby|node|deno|bun|tee|dd|rm|rmdir|mv|cp|ln|mkdir|touch|truncate|chmod|chown)([^[:alnum:]_]|$)|/dev/(tcp|udp)'
        # NUL-delimited, matching the `bash -n` check above. `for f in $(find)`
        # word-splits on whitespace, so a filename containing a space would make
        # grep run on two nonexistent fragments and exit 2 -- which `if` reads as
        # "no match", silently skipping the real file. The allowlist above would
        # already reject such a name today, but a gate that is only safe because
        # something earlier happens to catch it is not one worth relying on.
        fail=0
        while IFS= read -r -d "" f; do
          if grep -nE "$forbidden" "$f"; then
            echo "claude-message-timestamps: forbidden construct in $f (see denylist above)" >&2
            fail=1
          fi
        done < <(find $out -type f -print0)
        [ "$fail" -eq 0 ]
  '';

  # The statusline the managed settings point at. Runs from a system path
  # (/etc/claude-code/statusline-command.sh), so it ships at the system level
  # too. The shebang strip is asserted rather than assumed: a bare `drop 1`
  # would silently swallow a real line of script if the shebang ever moved or a
  # blank line crept in above it, and the breakage would only show at runtime.
  statusline = pkgs.writeShellApplication {
    name = "claude-statusline";
    runtimeInputs = with pkgs; [jq gawk git coreutils];
    text = let
      lines = lib.splitString "\n" (builtins.readFile cfg.statuslineSource);
      firstLine = lib.head lines;
    in
      assert lib.assertMsg (lib.hasPrefix "#!" firstLine)
      "jackpkgs.claude-managed-settings.statuslineSource line 1 is ${builtins.toJSON firstLine}, not a shebang -- the strip below would discard a real line of script.";
        lib.concatStringsSep "\n" (lib.drop 1 lines);
  };

  # `jq .` both validates (invalid JSON fails the build) and normalizes the
  # formatting, so the deployed bytes never depend on how the source file was
  # pretty-printed.
  managed-settings = pkgs.runCommand "claude-managed-settings.json" {} ''
    ${lib.getExe pkgs.jq} . ${cfg.settingsFile} > $out
  '';
in {
  options.jackpkgs.claude-managed-settings = {
    enable = lib.mkEnableOption "Claude Code managed settings (/etc/claude-code/managed-settings.json, plus the message-timestamps hooks and statusline it references)";

    settingsFile = lib.mkOption {
      type = lib.types.path;
      default = ./claude-managed-settings/managed-settings.json;
      defaultText = lib.literalExpression "./claude-managed-settings/managed-settings.json";
      description = ''
        The managed-settings.json to install; `jq`-validated at build time.
        The default is a vendored copy of garden's payload, not a policy-neutral
        one: it sets `permissions.defaultMode = "auto"` and
        `skipAutoPermissionPrompt = true`, which override per-user settings for
        every user on the host. Supply your own file to opt out. A replacement must keep the
        `statusLine` and hook commands pointing at the /etc/claude-code/ paths
        this module installs.
      '';
    };

    statuslineSource = lib.mkOption {
      type = lib.types.path;
      default = ./claude-managed-settings/statusline-command.sh;
      defaultText = lib.literalExpression "./claude-managed-settings/statusline-command.sh";
      description = ''
        Source of /etc/claude-code/statusline-command.sh. Must start with a
        shebang line (asserted); it is wrapped with its runtime inputs (jq,
        gawk, git, coreutils) on PATH.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.etc."claude-code/managed-settings.json".source = managed-settings;
    environment.etc."claude-code/hooks/message-timestamps".source = claude-message-timestamps;
    environment.etc."claude-code/statusline-command.sh".source = lib.getExe statusline;
  };
}
