# Behaviour tests pinning mdformat's `$` escaping.
#
# These exist because downstream sites enable MyST `dollarmath`, where a bare
# pair of dollar amounts (`$100k ... $200k`) parses as an inline math span and
# renders as garbled TeX. Whether the formatter adds, preserves, or strips `\$`
# therefore decides whether a page renders at all — and nothing else in this
# repo pins it, so a version or plugin bump can silently invert it. It has
# inverted once already, in an unnoticed direction, which is what prompted
# jmmaloney4/jackpkgs#361.
#
# The formatter under test is passed in from the flake's own treefmt config
# rather than rebuilt here, so the plugin set (mdformat-myst in particular)
# cannot drift out of sync with what these assertions claim to cover.
{
  pkgs,
  mdformatFormatter,
}: let
  inherit (pkgs) lib;

  command = mdformatFormatter.command;
  options = mdformatFormatter.options or [];

  # Format `input` with the configured mdformat and assert the result matches
  # `expected` byte for byte. Formatting is in place, so the fixture is copied
  # into the build directory first.
  mkCase = {
    name,
    input,
    expected,
  }:
    pkgs.runCommand "mdformat-escaping-${name}" {} ''
      cp ${pkgs.writeText "${name}-input.md" input} ./doc.md
      chmod +w ./doc.md

      ${command} ${lib.escapeShellArgs options} ./doc.md

      if ! diff -u ${pkgs.writeText "${name}-expected.md" expected} ./doc.md; then
        echo
        echo "FAIL: mdformat output for '${name}' changed."
        echo "If this was intentional, update the expectation AND check whether"
        echo "MyST dollarmath pages downstream still render — see jackpkgs#361."
        exit 1
      fi
      touch $out
    '';
in {
  # --- escapes ADDED where a bare $ is most likely to be misparsed -----------

  # The case that motivated this: bolded currency in prose.
  bold-currency-is-escaped = mkCase {
    name = "bold-currency-is-escaped";
    input = "Bold **$86,458** here.\n";
    expected = "Bold **\\$86,458** here.\n";
  };

  table-cell-currency-is-escaped = mkCase {
    name = "table-cell-currency-is-escaped";
    input = ''
      | a | b |
      | --- | --- |
      | $1 | $2 |
    '';
    expected = ''
      | a   | b   |
      | --- | --- |
      | \$1 | \$2 |
    '';
  };

  # --- escapes PRESERVED ------------------------------------------------------

  # The specific regression this guards: an earlier toolchain stripped `\$` as a
  # "redundant escape", which broke dollarmath pages downstream and led to a
  # SKIP=treefmt workaround. If this case ever fails, that has come back.
  existing-escape-is-preserved = mkCase {
    name = "existing-escape-is-preserved";
    input = "Escaped \\$300k stays.\n";
    expected = "Escaped \\$300k stays.\n";
  };

  # --- math left ALONE --------------------------------------------------------

  # Backslash doubling here (`\cdot` -> `\\cdot`) would render as a line break
  # rather than an operator, so this is load-bearing for MyST math too.
  inline-math-is-untouched = mkCase {
    name = "inline-math-is-untouched";
    input = "Inline $x \\cdot y$ and $\\log(z)$ here.\n";
    expected = "Inline $x \\cdot y$ and $\\log(z)$ here.\n";
  };

  block-math-is-untouched = mkCase {
    name = "block-math-is-untouched";
    input = ''
      $$
      \alpha \cdot \beta
      $$
    '';
    expected = ''
      $$
      \alpha \cdot \beta
      $$
    '';
  };

  # --- prose left alone -------------------------------------------------------

  # Unescaped currency in plain prose is NOT escaped today. Recorded so the
  # asymmetry with the bold/table cases above is a deliberate, visible fact
  # rather than something a reader assumes is covered.
  plain-prose-currency-is-untouched = mkCase {
    name = "plain-prose-currency-is-untouched";
    input = "Plain $100k to $200k.\n";
    expected = "Plain $100k to $200k.\n";
  };

  # Formatting an already-formatted document must be a no-op; without this a
  # future change could satisfy every case above on the first pass and still
  # oscillate on the second.
  idempotent-on-formatted-output = mkCase {
    name = "idempotent-on-formatted-output";
    input = "Bold **\\$86,458** and \\$300k with $x \\cdot y$.\n";
    expected = "Bold **\\$86,458** and \\$300k with $x \\cdot y$.\n";
  };
}
