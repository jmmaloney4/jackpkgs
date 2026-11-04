# Behaviour of the Dex-logging `logcli` wrapper, against fake logcli and kubelogin.
# Covers the non-interactive path, which is what a redirected shell gets; the
# interactive one differs only in leaving kubelogin's browser flags off.
{pkgs}: let
  fakeLoki = pkgs.writeShellScriptBin "logcli" ''
    echo "RAN args=[$*] token=[''${LOKI_BEARER_TOKEN:-}]"
  '';
  fakeKubelogin = pkgs.writeShellScriptBin "kubectl-oidc_login" ''
    echo "$*" >>"$KUBELOGIN_LOG"
    case "''${FAKE_LOGIN:-ok}" in
      ok) echo '{"status":{"token":"tok123"}}' ;;
      fail) exit 1 ;;
      empty) echo '{"status":{}}' ;;
    esac
  '';
  wrapper = import ../lib/logcli-wrapper.nix {
    inherit pkgs;
    loki = fakeLoki;
    kubelogin = fakeKubelogin;
  };
in {
  behaviour = pkgs.runCommand "logcli-wrapper-behaviour" {} ''
    export HOME="$TMPDIR/home" KUBELOGIN_LOG="$TMPDIR/login.log"
    mkdir -p "$HOME"
    w=${wrapper}/bin/logcli
    fail() { echo "FAIL: $1"; cat "$KUBELOGIN_LOG" 2>/dev/null; exit 1; }
    logins() { if [ -e "$KUBELOGIN_LOG" ]; then wc -l <"$KUBELOGIN_LOG" | tr -d ' '; else echo 0; fi; }
    reset() { rm -f "$KUBELOGIN_LOG"; unset LOKI_ADDR LOKI_BEARER_TOKEN LOKI_BEARER_TOKEN_FILE LOKI_USERNAME LOKI_PASSWORD FAKE_LOGIN || true; }

    # A hosted name gets a token, passed by environment and never on the command line.
    reset; export LOKI_ADDR=https://loki.cavinsresearch.io
    got="$($w labels namespace)"
    [ "$got" = "RAN args=[labels namespace] token=[tok123]" ] || fail "hosted: $got"
    grep -q -- '--oidc-issuer-url=https://dex.roomofrequirement.xyz/dex' "$KUBELOGIN_LOG" || fail "issuer"
    grep -q -- '--oidc-client-id=loki' "$KUBELOGIN_LOG" || fail "client"
    grep -q -- '--oidc-extra-scope=groups' "$KUBELOGIN_LOG" || fail "groups scope"
    grep -q -- '--oidc-extra-scope=offline_access' "$KUBELOGIN_LOG" || fail "refresh scope"

    # Tokens are cached per host.
    grep -q -- "--token-cache-dir=$HOME/.cache/logcli-dex/loki.cavinsresearch.io" "$KUBELOGIN_LOG" || fail "cache dir"
    [ "$(stat -c %a "$HOME/.cache/logcli-dex/loki.cavinsresearch.io" 2>/dev/null || stat -f %Lp "$HOME/.cache/logcli-dex/loki.cavinsresearch.io")" = 700 ] || fail "cache mode"
    reset; export LOKI_ADDR=https://loki.ergodic.cc/
    $w labels >/dev/null
    grep -q -- "logcli-dex/loki.ergodic.cc " "$KUBELOGIN_LOG" || grep -q -- "logcli-dex/loki.ergodic.cc$" "$KUBELOGIN_LOG" || fail "second host cache"

    # With no terminal, a browser is never opened. Nix gives a builder a terminal
    # on stderr, so both streams are redirected to get a shell without one.
    reset; export LOKI_ADDR=https://loki.cavinsresearch.io
    $w labels >/dev/null </dev/null 2>/dev/null
    grep -q -- '--skip-open-browser' "$KUBELOGIN_LOG" || fail "no-terminal browser"
    grep -q -- '--authentication-timeout-sec=1' "$KUBELOGIN_LOG" || fail "no-terminal timeout"

    # --addr beats the environment, in both spellings.
    reset; export LOKI_ADDR=https://loki.cavinsresearch.io
    got="$($w --addr http://localhost:3100 labels)"
    case "$got" in *"token=[]"*) ;; *) fail "--addr local: $got" ;; esac
    [ "$(logins)" = 0 ] || fail "--addr local logged in"
    reset
    got="$($w --addr=https://loki.cavinsresearch.io labels)"
    case "$got" in *"token=[tok123]"*) ;; *) fail "--addr= hosted: $got" ;; esac

    # No login for: other addresses, an explicit token, or help and version.
    for a in http://localhost:3100 http://127.0.0.1:8001/api/v1/namespaces/x/services/y:3100/proxy https://example.io "" \
      https://loki.example.io \
      https://loki.cavinsresearch.io@evil.com \
      https://loki.cavinsresearch.io.evil.com \
      https://x@loki.cavinsresearch.io \
      http://loki.cavinsresearch.io \
      https://loki.cavinsresearch.io:8443 \
      https://loki.cavinsresearch.io/x; do
      reset; export LOKI_ADDR="$a"
      got="$($w labels)"
      case "$got" in *"token=[]"*) ;; *) fail "addr '$a': $got" ;; esac
      [ "$(logins)" = 0 ] || fail "addr '$a' logged in"
    done
    reset; export LOKI_ADDR=https://loki.cavinsresearch.io LOKI_BEARER_TOKEN=mine
    got="$($w labels)"
    [ "$got" = "RAN args=[labels] token=[mine]" ] || fail "explicit token: $got"
    [ "$(logins)" = 0 ] || fail "explicit token logged in"
    reset; export LOKI_ADDR=https://loki.cavinsresearch.io LOKI_BEARER_TOKEN_FILE=/x
    $w labels >/dev/null; [ "$(logins)" = 0 ] || fail "token file logged in"
    for v in LOKI_USERNAME LOKI_PASSWORD; do
      reset; export LOKI_ADDR=https://loki.cavinsresearch.io "$v=x"
      $w labels >/dev/null; [ "$(logins)" = 0 ] || fail "$v logged in"
    done
    for args in "--help" "--version" "query --help" "help" "--bearer-token=x labels" "--bearer-token-file=/x labels" "--username=u labels" "--password=p labels"; do
      reset; export LOKI_ADDR=https://loki.cavinsresearch.io
      # shellcheck disable=SC2086
      $w $args >/dev/null
      [ "$(logins)" = 0 ] || fail "'$args' logged in"
    done
    reset; export LOKI_ADDR=https://loki.cavinsresearch.io
    $w >/dev/null; [ "$(logins)" = 0 ] || fail "no args logged in"

    # A failed login stops loudly and never runs logcli without a token.
    reset; export LOKI_ADDR=https://loki.cavinsresearch.io FAKE_LOGIN=fail
    if got="$($w labels </dev/null 2>"$TMPDIR/err")"; then fail "failed login exited 0: $got"; fi
    case "$got" in *RAN*) fail "ran logcli after a failed login" ;; esac
    grep -q 'could not get a Dex token' "$TMPDIR/err" || fail "failed login message"
    grep -q 'no terminal' "$TMPDIR/err" || fail "no-terminal hint"
    reset; export LOKI_ADDR=https://loki.cavinsresearch.io FAKE_LOGIN=empty
    if got="$($w labels </dev/null 2>"$TMPDIR/err")"; then fail "empty credential exited 0: $got"; fi
    case "$got" in *RAN*) fail "ran logcli with no token" ;; esac
    grep -q 'returned no token' "$TMPDIR/err" || fail "empty credential message"

    touch "$out"
  '';
}
