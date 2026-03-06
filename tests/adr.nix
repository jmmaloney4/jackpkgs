# Script-behaviour tests for the adr-conflict-check package.
#
# Each attribute is a derivation that runs the script against a fixture
# directory and asserts the expected exit code.  Added to the flake's
# `checks` attrset so `nix flake check` executes them.
{ pkgs, adr-conflict-check }:
let
  fixtureRoot = ./fixtures/adr;

  # Run the script against a fixture dir.
  # shouldPass: true  → expect exit 0
  # shouldPass: false → expect exit 1 (any violation)
  mkAdrTest = { name, fixture, shouldPass }:
    pkgs.runCommand "adr-conflict-check-${name}" { } ''
      set +e
      ${pkgs.lib.getExe adr-conflict-check} --adr-dir "${fixtureRoot}/${fixture}"
      rc=$?
      set -e
      ${if shouldPass then ''
        if [ $rc -ne 0 ]; then
          echo "FAIL: expected exit 0 but got $rc"
          exit 1
        fi
      '' else ''
        if [ $rc -eq 0 ]; then
          echo "FAIL: expected non-zero exit but got 0"
          exit 1
        fi
      ''}
      touch $out
    '';
in
{
  # A perfectly-numbered sequence (000-003) passes.
  clean = mkAdrTest {
    name = "clean";
    fixture = "adr-clean";
    shouldPass = true;
  };

  # Two files share number 002 — must fail.
  duplicate = mkAdrTest {
    name = "duplicate";
    fixture = "adr-duplicate";
    shouldPass = false;
  };

  # 003 is absent between 002 and 004 — must fail.
  gap = mkAdrTest {
    name = "gap";
    fixture = "adr-gap";
    shouldPass = false;
  };

  # A file doesn't start with NNN- — must fail.
  malformed = mkAdrTest {
    name = "malformed";
    fixture = "adr-malformed";
    shouldPass = false;
  };

  # Only README.md present; no ADRs yet — should pass (nothing to check).
  empty = mkAdrTest {
    name = "empty";
    fixture = "adr-empty";
    shouldPass = true;
  };
}
