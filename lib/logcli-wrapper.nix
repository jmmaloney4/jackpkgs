# `logcli`, logging in through Dex when it talks to a hosted Loki name
# (room-of-requirement/seven ADR 032).
#
# Pointed at `https://loki.*` with no credentials of its own, it gets a token from
# kubelogin and runs the real logcli with it. kubelogin reuses a cached token, and
# refreshes it without a browser while it can. Anything else (a port-forward, a
# kubectl proxy, an explicit token, `--help`) goes straight to logcli.
#
# Tokens are cached per host: a person can hold different logins for different
# names, and a platform token is refused on a tenant name.
#
# A shell with no terminal, such as an agent's, never opens a browser. It can use a
# cached token and otherwise fails with a message saying what to do.
{
  pkgs,
  loki ? pkgs.grafana-loki,
  kubelogin ? pkgs.kubelogin-oidc,
}:
pkgs.writeShellApplication {
  name = "logcli";
  runtimeInputs = [kubelogin pkgs.coreutils pkgs.jq];
  text = ''
    real=${loki}/bin/logcli
    issuer=https://dex.roomofrequirement.xyz/dex
    client=loki

    addr="''${LOKI_ADDR:-}"
    if [[ $# -eq 0 || "$1" == help ]]; then
      exec "$real" "$@"
    fi
    prev=""
    for arg in "$@"; do
      if [[ "$prev" == --addr ]]; then
        addr="$arg"
      fi
      case "$arg" in
        --addr=*)
          addr="''${arg#--addr=}"
          ;;
        --help | --help-long | --help-man | -h | --version | --completion-script-bash | --completion-script-zsh)
          exec "$real" "$@"
          ;;
        --bearer-token | --bearer-token=* | --bearer-token-file | --bearer-token-file=* | --username | --username=* | --password | --password=*)
          exec "$real" "$@"
          ;;
      esac
      prev="$arg"
    done

    if [[ -n "''${LOKI_BEARER_TOKEN:-}''${LOKI_BEARER_TOKEN_FILE:-}''${LOKI_USERNAME:-}''${LOKI_PASSWORD:-}" ]]; then
      exec "$real" "$@"
    fi
    case "$addr" in
      https://loki.*) ;;
      *) exec "$real" "$@" ;;
    esac

    host="''${addr#https://}"
    host="''${host%%/*}"
    cache="''${XDG_CACHE_HOME:-$HOME/.cache}/logcli-dex/$host"
    umask 077
    mkdir -p "$cache"

    login_flags=()
    if [[ ! -t 0 && ! -t 2 ]]; then
      login_flags=(--skip-open-browser --authentication-timeout-sec=1)
    fi

    if ! credential="$(kubectl-oidc_login get-token \
      --oidc-issuer-url="$issuer" \
      --oidc-client-id="$client" \
      --oidc-extra-scope=profile \
      --oidc-extra-scope=groups \
      --oidc-extra-scope=offline_access \
      --token-cache-dir="$cache" \
      "''${login_flags[@]}")"; then
      echo "logcli: could not get a Dex token for $host." >&2
      if [[ ''${#login_flags[@]} -gt 0 ]]; then
        echo "logcli: this shell has no terminal to log in from. Run logcli once in a terminal, or set LOKI_BEARER_TOKEN." >&2
      fi
      exit 1
    fi
    if ! token="$(jq -er '.status.token' <<<"$credential")"; then
      echo "logcli: kubelogin returned no token for $host." >&2
      exit 1
    fi
    export LOKI_BEARER_TOKEN="$token"
    exec "$real" "$@"
  '';
}
