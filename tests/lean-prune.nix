# Behavioural check of `pruneNondeterministic` (ADR-052) on a synthetic tree.
#
# tests/lean.nix can only inspect the emitted shell text. What matters is what
# the fragment DOES to a `.lake/packages` tree, and the failure modes are
# silent: deleting traces makes Lake re-elaborate Mathlib, keeping logs leaves
# the FOD hash nondeterministic, and neither shows up until a 6.8 GB build.
{
  lib,
  pkgs,
}: let
  leanLib = import ../lib/lean.nix {inherit lib;};
in {
  prune =
    pkgs.runCommand "lean-prune-canonical" {
      nativeBuildInputs = [pkgs.jq pkgs.findutils pkgs.diffutils];
    } ''
      set -euo pipefail
      P=$TMPDIR/packages
      lm=$P/mathlib/.lake/build/lib/lean
      mkdir -p $lm/Mathlib $lm/Cache $P/mathlib/.lake/build/bin $P/mathlib/.lake/build/ir/Cache \
               $P/mathlib/.git $P/batteries/.lake/build/lib/lean/Batteries \
               $P/proofwidgets/widget/js

      # Delivered by the archive: a trace with no log. Must survive, byte-for-byte
      # semantically (key order is canonicalised, so compare through jq).
      echo '{"schemaVersion":"2025-09-10","depHash":"abc","outputs":{"o":["1.olean"]}}' > $lm/Mathlib/Init.trace
      # Built locally with an absolute path in its log: must survive, log emptied.
      echo '{"outputs":{"o":["2.olean"]},"depHash":"def","log":[{"message":"LEAN_PATH=/home/x/a","level":"trace"}]}' \
        > $P/batteries/.lake/build/lib/lean/Batteries/OpenPrivate.trace
      # Needed or Lake runs npm.
      echo '{"depHash":"w","log":[{"message":"/tmp/abs"}]}' > $P/proofwidgets/widget/js/lake.trace
      # Locally built `cache` tool and its leftovers: must go.
      echo '{}' > $lm/Cache/Cli.trace
      echo x > $lm/Cache.olean
      echo x > $P/mathlib/.lake/build/bin/cache
      echo x > $P/mathlib/.lake/build/ir/Cache/Main.setup.json
      echo x > $P/mathlib/.lake/build/ir/Cache/Main.rsp
      echo x > $P/mathlib/.git/HEAD
      chmod -R u+w $P

      ${leanLib.pruneNondeterministic "$P"}

      fail() { echo "FAIL: $*" >&2; exit 1; }
      for gone in $lm/Cache $lm/Cache.olean $P/mathlib/.lake/build/bin \
                  $P/mathlib/.lake/build/ir/Cache $P/mathlib/.git; do
        test ! -e "$gone" || fail "$gone survived the prune"
      done
      for kept in $lm/Mathlib/Init.trace $P/batteries/.lake/build/lib/lean/Batteries/OpenPrivate.trace \
                  $P/proofwidgets/widget/js/lake.trace; do
        test -f "$kept" || fail "$kept was deleted; Lake treats a missing trace as stale"
      done
      test "$(jq -r .depHash $lm/Mathlib/Init.trace)" = abc || fail "depHash changed"
      test "$(jq -r '.outputs.o[0]' $P/batteries/.lake/build/lib/lean/Batteries/OpenPrivate.trace)" = 2.olean || fail "outputs changed"
      test "$(jq -c .log $P/batteries/.lake/build/lib/lean/Batteries/OpenPrivate.trace)" = '[]' || fail "log not emptied"
      test "$(jq -c .log $P/proofwidgets/widget/js/lake.trace)" = '[]' || fail "widget log not emptied"
      jq -e 'has("log") | not' $lm/Mathlib/Init.trace >/dev/null || fail "added a log to a log-less trace"
      grep -rl '/home/x\|/tmp/abs' $P && fail "host path survived" || true

      # Idempotent: a second pass is a no-op.
      cp -r $P $TMPDIR/once
      ${leanLib.pruneNondeterministic "$P"}
      diff -r $TMPDIR/once $P || fail "prune is not idempotent"

      # A trace jq cannot parse must fail the build, not be left in place.
      echo 'not json' > $lm/Mathlib/Bad.trace
      if (${leanLib.pruneNondeterministic "$P"}) 2>/dev/null; then fail "unparseable trace was tolerated"; fi
      touch $out
    '';
}
