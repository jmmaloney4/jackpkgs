# jackpkgs.shell — the interactive shell environment for Home Manager
# (ADR-051): zsh, starship, zellij, zoxide, direnv, eza, fzf, bat, gpg, jq and
# the OpenSSH client defaults.
#
# Promoted from garden `nixfiles/home/programs/{default,zsh,starship,zellij,ssh}.nix`
# and the shell-facing bits of `home/common/default.nix`. One module rather
# than six: what a consumer stops having to know is that these settings
# cross-reference each other (zsh integrations for eza/fzf, zellij aliases,
# the forwarded-agent socket shared by zsh and ssh_config). It is opinionated
# taste on purpose (ADR-051 Decision 4): a consumer who dislikes one program
# overrides that program's own `programs.<name>.enable`. Security-relevant
# taste: the ssh client sets `ForwardAgent = true` for every host (`Host *`);
# override `programs.ssh.settings."*".ForwardAgent` to narrow it.
#
# `home.stateVersion` is deliberately NOT set here: it is per-account state
# the consumer owns, and Home Manager fails loudly when it is missing.
{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) getExe mkEnableOption mkIf mkMerge mkOption optionalString types;
  cfg = config.jackpkgs.shell;

  # Homebrew's prefix. Apple Silicon only, and deliberately so: the fleet's
  # darwin hosts are all aarch64-darwin. Single-sourced so the `brew shellenv`
  # call and the completion exemption below cannot drift apart.
  homebrewPrefix = "/opt/homebrew";

  # Completion directories we knowingly trust even though they fail compaudit's
  # ownership check, so compinit can skip auditing them instead of prompting.
  #
  # Homebrew's prefix is owned by whichever account installed it, and compaudit
  # only accepts directories owned by root or the current user -- so for every
  # *other* user it stops the shell with "continue [y] or abort compinit [n]?".
  # It bites nested shells specifically: `brew shellenv` prepends that
  # directory to an exported FPATH, so every child shell (zellij pane, direnv,
  # editor terminal) inherits it and trips compinit before ~/.zshrc starts.
  trustedCompletionDirs = lib.optionals pkgs.stdenv.hostPlatform.isDarwin [
    "${homebrewPrefix}/share/zsh/site-functions"
  ];

  # Local console session: prefer the configured local agent socket if it
  # exists. Empty when no socket is configured.
  localAgentSnippet = optionalString (cfg.localSshAgentSocket != null) ''
    if [[ -S "${shellSocket}" ]]; then
      export SSH_AUTH_SOCK="${shellSocket}"
    fi'';

  # `~/…` form for ssh_config, `$HOME/…` form for the shell.
  sshConfigSocket = "~/${cfg.localSshAgentSocket}";
  shellSocket = "$HOME/${cfg.localSshAgentSocket}";
in {
  options.jackpkgs.shell = {
    enable = mkEnableOption "jackpkgs' interactive shell environment (zsh, starship, zellij, zoxide, direnv, eza, fzf, bat, gpg, jq, ssh client; note the ssh client forwards the agent to every host, ForwardAgent = true)";

    localSshAgentSocket = mkOption {
      # nullOr + default null: "no local agent socket to prefer" is an intended
      # state (a headless host), so it is spelled instead of left to fail.
      # strMatching: the value is interpolated unescaped into a zsh
      # test and an ssh_config `Match exec` line, so shell metacharacters
      # (quotes, `$`, backticks, backslash) or a leading "/" would yield broken
      # config or command substitution. Allow only path-like characters
      # (letters, digits, `. _ @ + = , : -`, space and inner `/`) and refuse the
      # rest at the type.
      type = types.nullOr (types.strMatching "[A-Za-z0-9._@+=,:-][A-Za-z0-9._@+=,:/ -]*");
      default = null;
      example = "Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock";
      description = ''
        Path, relative to $HOME, of a local SSH agent socket to prefer in
        console (non-SSH) sessions. When set, zsh exports it as SSH_AUTH_SOCK
        if the socket exists, and ssh_config uses it as `IdentityAgent` only
        for local sessions where it exists. In inbound SSH sessions it is
        ignored so the forwarded agent is used.

        `null` leaves both alone. The forwarded-agent socket stabilisation for
        SSH sessions is always on.
      '';
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      home.sessionVariables.MANPAGER = "${getExe pkgs.bat} -l man -p";
      home.shellAliases.l = "ls -al";

      programs.bat.enable = true;
      programs.bat.config.pager = "${getExe pkgs.less} -FRM";

      programs.direnv.enable = true;
      programs.direnv.nix-direnv.enable = true;
      programs.direnv.silent = true;

      programs.eza.enable = true;
      programs.eza.enableZshIntegration = true;
      programs.eza.git = true;
      programs.eza.icons = "auto";

      programs.fzf.enable = true;
      programs.fzf.enableZshIntegration = true;
      programs.fzf.defaultOptions = ["--height 40%" "--border"];
      programs.fzf.historyWidget.options = ["--border-label='╢ ZSH History ╟'" "--border-label-pos=3:bottom" "--color=label:italic:black"];
      programs.fzf.fileWidget.options = ["--preview 'head -n 20 {} | nl'"];

      # See also: modules/common/gnupg-agent.nix
      programs.gpg.enable = true;

      programs.jq.enable = true;

      programs.zoxide.enable = true;

      programs.zsh.enable = true;
      programs.zsh.autosuggestion.enable = true;
      programs.zsh.enableCompletion = true;
      programs.zsh.syntaxHighlighting.enable = true;
      programs.zsh.historySubstringSearch.enable = true;

      # `compinit -u` would silence the prompt by trusting *everything* in
      # fpath. Instead, audit fpath minus the known-untrusted directories
      # ourselves and only then skip compinit's own check, so a new insecure
      # directory anywhere else still surfaces. compaudit accepts the
      # directories to check as positional arguments.
      programs.zsh.completionInit = ''
        autoload -U compaudit compinit
        () {
          local -a trusted=( ${lib.concatStringsSep " " trustedCompletionDirs} )
          if compaudit ''${fpath:|trusted} >/dev/null 2>&1; then
            compinit -u
          else
            compinit
          fi
        }
      '';

      programs.zsh.shellAliases = {
        # SSH agent
        "check-ssh" = "ssh-add -l";

        # Zellij helpers
        "zj" = "zellij";
        "zja" = "zellij attach";
        "zjl" = "zellij list-sessions";
        "zjk" = "zellij kill-session";
      };

      programs.zsh.history = rec {
        size = 1000000;
        save = size;
        share = true;
        extended = true;
        expireDuplicatesFirst = true;
        ignoreDups = false;
        ignoreSpace = true;
      };

      programs.zsh.initContent = lib.mkMerge [
        (lib.mkIf pkgs.stdenv.hostPlatform.isDarwin ''
          if [[ -x ${homebrewPrefix}/bin/brew ]]; then
            eval "$(${homebrewPrefix}/bin/brew shellenv)"
          fi
        '')

        ''
          # SSH agent socket management.
          #
          # For SSH sessions (SSH_CONNECTION set): sshd has already set
          # SSH_AUTH_SOCK to a per-login forwarded agent socket under
          # ~/.ssh/agent/. That path changes on every fresh login, so we
          # stabilise it by symlinking to a fixed path; zellij/tmux sessions
          # that survive reconnects can then still find the agent.
          #
          # Limitation: once the original forwarded-agent tunnel is dead, the
          # remote machine cannot resurrect it. Recovery is one fresh SSH login
          # from the local machine, which updates the stable symlink for any
          # long-lived remote shells (see refresh-ssh-agent below).
          if [[ -z "$SSH_CONNECTION" ]]; then
            # (no local agent configured: nothing to prefer)
            :
            ${localAgentSnippet}
          else
            STABLE_SOCK="$HOME/.ssh/ssh_auth_sock"
            if [[ -n "$SSH_AUTH_SOCK" && "$SSH_AUTH_SOCK" != "$STABLE_SOCK" ]]; then
              mkdir -p "$HOME/.ssh"
              ln -sf "$SSH_AUTH_SOCK" "$STABLE_SOCK"
            fi
            export SSH_AUTH_SOCK="$STABLE_SOCK"
          fi

          refresh-ssh-agent() {
            local host="$1"

            if [[ -z "$host" ]]; then
              echo "usage: refresh-ssh-agent <host>" >&2
              return 2
            fi

            # The command is double-quoted, so every $ that must expand on the
            # REMOTE host is escaped; unescaped, $HOME/$SSH_AUTH_SOCK expand
            # here and the remote re-points its stable symlink at this
            # machine's socket path.
            ssh -tt "$host" "zsh -lic 'test -S \"\$HOME/.ssh/ssh_auth_sock\" && rm -f \"\$HOME/.ssh/ssh_auth_sock\"; test -S \"\$SSH_AUTH_SOCK\" || exit 1; ln -sf \"\$SSH_AUTH_SOCK\" \"\$HOME/.ssh/ssh_auth_sock\"; test -S \"\$HOME/.ssh/ssh_auth_sock\"'" </dev/null
          }
        ''

        # Set window title to current directory for Zellij/Terminal
        ''
          set_window_title() {
            print -Pn "\e]0;%~\a"
          }
          precmd_functions+=(set_window_title)
        ''
      ];

      programs.starship.enable = true;
      programs.starship.settings = {
        battery = {
          full_symbol = "";
          charging_symbol = "";
          discharging_symbol = "";
          unknown_symbol = "";
          empty_symbol = "!";
        };

        battery.display = [
          {
            threshold = 10;
            style = "bold red";
          }
          {
            threshold = 30;
            style = "bold yellow";
          }
          {
            threshold = 100;
            style = "bold green";
          }
        ];

        character = {
          error_symbol = "[✖](bold red) ";
        };

        cmd_duration = {
          min_time = 100;
          format = "took [$duration]($style)";
          show_notifications = true;
        };

        directory = {
          truncation_length = 5;
          truncate_to_repo = false;
          format = "[$path]($style)[$lock_symbol]($lock_style) ";
          disabled = false;
        };

        git_commit = {
          commit_hash_length = 8;
          style = "bold white";
          disabled = false;
          only_detached = false;
          tag_disabled = false;
        };

        git_metrics = {
          disabled = false;
          format = "[+$added]($added_style)[/](bold white)[-$deleted]($deleted_style) ";
        };

        git_status = {
          conflicted = "⚔️ ";
          ahead = "🏎️ ×\${count} ";
          behind = "🐢 ×\${count} ";
          diverged = "🔱 🏎️ ×\${ahead_count} 🐢 ×\${behind_count} ";
          untracked = "🛤️ ×\${count} ";
          stashed = "📦 ";
          modified = "📝 ×\${count} ";
          staged = "🗃️ ×\${count} ";
          renamed = "👣 ×\${count} ";
          deleted = "🗑️ ×\${count} ";
          style = "bright-white";
          format = "$all_status$ahead_behind";
        };

        username = {
          style_user = "bold dimmed blue";
          show_always = true;
          disabled = false;
          format = "[$user]($style)@";
        };

        hostname = {
          ssh_only = false;
          trim_at = "-";
          style = "bold dimmed white";
          disabled = false;
        };

        julia = {
          format = "[$symbol$version]($style) ";
          symbol = "ஃ ";
          style = "bold green";
        };

        package = {
          disabled = true;
        };

        python = {
          format = "[$symbol$version]($style) ";
          style = "bold green";
        };

        rust = {
          format = "[$symbol$version]($style) ";
          style = "bold green";
        };

        time = {
          time_format = "%T";
          format = "$time($style) ";
          style = "bright-white";
          disabled = false;
        };
      };

      programs.zellij = {
        enable = true;
        settings = {
          layout = "compact";
          ui = {
            pane_frames = true;
            status_bar = true;
            tab_bar = true;
          };
        };
      };

      programs.ssh = {
        enable = true;
        enableDefaultConfig = false;
        package = pkgs.openssh;
        settings."*" = {
          ForwardAgent = true;
          ServerAliveInterval = 30;
          ServerAliveCountMax = 3;
        };
      };
      # ~/.ssh/authorized_keys is deliberately NOT managed here. Inbound SSH is
      # authorized at the system level (jackpkgs.ssh.authorizedKeysUsers ->
      # users.users.<u>.openssh.authorizedKeys.keys), which publishes keys
      # outside $HOME. A home.file copy would be duplication, and it turns the
      # path into a /nix/store symlink: the first out-of-band append (an
      # ssh-copy-id) replaces the symlink with a regular file and every later
      # Home Manager activation aborts with "would be clobbered" -- which fails
      # the whole NixOS switch (garden: itachi sat six weeks on a stale
      # generation that way). Leaving it unmanaged makes that state unreachable.
    }

    (mkIf (cfg.localSshAgentSocket != null) {
      programs.ssh.extraConfig = ''
        # Use the local agent only for local sessions where its socket exists.
        # In inbound SSH sessions, leave IdentityAgent unset so OpenSSH uses
        # the forwarded agent from SSH_AUTH_SOCK instead.
        Match exec "test -z \"$SSH_CONNECTION\" && test -S \"$HOME/${cfg.localSshAgentSocket}\""
          IdentityAgent "${sshConfigSocket}"
      '';
    })
  ]);
}
