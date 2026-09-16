# Tests for the pure helpers behind `jackpkgs.lean` (lib/lean.nix).
#
# These functions carry the module's whole safety argument: a `lean-toolchain`
# pin that jackpkgs can't resolve to a binary release must be REFUSED loudly,
# not silently downgraded to a source build or a path traversal. Untested,
# that argument is only an assertion. So the throw paths get at least as much
# coverage here as the happy paths -- see especially
# `testPruneNondeterministicOutIsShellExpandable` below, which is written
# specifically to catch the `lib.escapeShellArg` regression described in
# lib/lean.nix.
{lib}: let
  helpers = import ../lib/lean.nix {inherit lib;};
  inherit
    (helpers)
    trim
    parseToolchain
    resolveManifestPath
    loadManifest
    readLakeManifest
    hasMathlib
    pruneNondeterministic
    ;

  # `builtins.tryEval` catches `builtins.throw`/`abort` but NOT fatal type
  # coercion errors (e.g. `toString` on an attrset) -- every throw in
  # lib/lean.nix uses `builtins.toJSON` for interpolation, so it is safe to
  # probe with tryEval here.
  throws = expr: !(builtins.tryEval expr).success;

  fixturesRoot = ../tests/fixtures/lean;

  resolveManifestFixtures = fixturesRoot + "/resolve-manifest";
  vendoredDir = resolveManifestFixtures + "/vendored";
  upstreamDir = resolveManifestFixtures + "/upstream";

  manifestsDir = fixturesRoot + "/manifests";

  lakeManifestWithMathlib = fixturesRoot + "/lake-manifest-with-mathlib";
  lakeManifestWithoutMathlib = fixturesRoot + "/lake-manifest-without-mathlib";
  lakeManifestMissing = fixturesRoot + "/lake-manifest-missing";
in {
  # ---------------------------------------------------------------------
  # trim
  # ---------------------------------------------------------------------

  testTrimStripsLeadingTabs = {
    expr = trim "\t\thello";
    expected = "hello";
  };

  testTrimStripsTrailingNewline = {
    expr = trim "hello\n";
    expected = "hello";
  };

  testTrimStripsLeadingAndTrailingWhitespace = {
    expr = trim "  \t hello world \t\n";
    expected = "hello world";
  };

  testTrimAllWhitespaceInputYieldsEmpty = {
    expr = trim "   \t\t\n  ";
    expected = "";
  };

  testTrimEmptyStringYieldsEmpty = {
    expr = trim "";
    expected = "";
  };

  # ---------------------------------------------------------------------
  # parseToolchain
  # ---------------------------------------------------------------------

  testParseToolchainHappyPath = {
    expr = parseToolchain "leanprover/lean4:v4.34.0\n";
    expected = "v4.34.0";
  };

  testParseToolchainToleratesLeadingAndTrailingWhitespace = {
    expr = parseToolchain "\t  leanprover/lean4:v4.34.0  \t\n";
    expected = "v4.34.0";
  };

  testParseToolchainThrowsOnNonLeanprover4Pin = {
    # A bare local-directory pin (a legal `lean-toolchain` value Lean itself
    # accepts, but one that cannot be resolved to a binary release).
    expr = throws (parseToolchain "../my-toolchain\n");
    expected = true;
  };

  testParseToolchainThrowsOnEmptyString = {
    expr = throws (parseToolchain "");
    expected = true;
  };

  testParseToolchainThrowsOnPathTraversalTag = {
    # The reason the `[A-Za-z0-9._-]` guard exists: without it this pin would
    # be interpolated straight into a manifest path in resolveManifestPath.
    expr = throws (parseToolchain "leanprover/lean4:../../etc/passwd");
    expected = true;
  };

  testParseToolchainThrowsOnTagWithDisallowedCharacters = {
    expr = throws (parseToolchain "leanprover/lean4:v4.34.0; rm -rf /");
    expected = true;
  };

  # ---------------------------------------------------------------------
  # resolveManifestPath
  # ---------------------------------------------------------------------

  testResolveManifestPathPrefersVendoredOverUpstream = {
    # Both ./vendored/v4.34.0.nix and ./upstream/v4.34.0.nix exist; vendored
    # must win.
    expr = resolveManifestPath {
      inherit vendoredDir upstreamDir;
      tag = "v4.34.0";
    };
    expected = toString (vendoredDir + "/v4.34.0.nix");
  };

  testResolveManifestPathFallsBackToUpstreamWhenNoVendoredCopy = {
    # Only ./upstream/v4.20.0.nix exists.
    expr = resolveManifestPath {
      inherit vendoredDir upstreamDir;
      tag = "v4.20.0";
    };
    expected = toString (upstreamDir + "/v4.20.0.nix");
  };

  testResolveManifestPathThrowsWhenNeitherVendoredNorUpstreamExists = {
    # `builtins.tryEval` catches the throw but discards its message, so the
    # doc comment's "names `just lean-toolchain-fetch`" claim is verified by
    # reading lib/lean.nix's throw site (it interpolates
    # `just lean-toolchain-fetch ${lib.removePrefix "v" tag}` directly) rather
    # than by re-deriving the string here.
    expr = throws (resolveManifestPath {
      inherit vendoredDir upstreamDir;
      tag = "v9.9.9";
    });
    expected = true;
  };

  # ---------------------------------------------------------------------
  # loadManifest
  # ---------------------------------------------------------------------

  testLoadManifestPlainAttrsetShape = {
    expr = loadManifest {
      path = manifestsDir + "/plain-attrset.nix";
      inherit upstreamDir;
      tag = "v4.34.0";
    };
    expected = {
      tag = "v4.34.0";
      toolchain = "lean4-binary-placeholder";
    };
  };

  testLoadManifestFunctionShapeYieldsSameResultAsPlainAttrset = {
    expr =
      loadManifest {
        path = manifestsDir + "/function-shape.nix";
        inherit upstreamDir;
        tag = "v4.34.0";
      }
      == loadManifest {
        path = manifestsDir + "/plain-attrset.nix";
        inherit upstreamDir;
        tag = "v4.34.0";
      };
    expected = true;
  };

  testLoadManifestThrowsWhenTagDisagreesWithManifest = {
    # tag-mismatch.nix declares `tag = "v9.9.9"`; requesting "v4.34.0" must
    # throw rather than silently serve the wrong compiler.
    expr = throws (loadManifest {
      path = manifestsDir + "/tag-mismatch.nix";
      inherit upstreamDir;
      tag = "v4.34.0";
    });
    expected = true;
  };

  testLoadManifestThrowsWhenManifestHasNoToolchainAttribute = {
    expr = throws (loadManifest {
      path = manifestsDir + "/missing-toolchain.nix";
      inherit upstreamDir;
      tag = "v4.34.0";
    });
    expected = true;
  };

  # ---------------------------------------------------------------------
  # readLakeManifest / hasMathlib
  # ---------------------------------------------------------------------

  testHasMathlibTrueWhenManifestListsMathlib = {
    expr = hasMathlib (readLakeManifest lakeManifestWithMathlib);
    expected = true;
  };

  testHasMathlibFalseWhenManifestOmitsMathlib = {
    expr = hasMathlib (readLakeManifest lakeManifestWithoutMathlib);
    expected = false;
  };

  testReadLakeManifestThrowsOnMissingFile = {
    expr = throws (readLakeManifest lakeManifestMissing);
    expected = true;
  };

  # ---------------------------------------------------------------------
  # pruneNondeterministic
  # ---------------------------------------------------------------------
  #
  # This is a shell-fragment generator, not a value -- the only way to test
  # it meaningfully is to inspect the emitted text for the specific failure
  # mode the doc comment warns about: `lib.escapeShellArg` single-quotes
  # `$out`, so `rm -rf -- '$out/…'` is a no-op the shell never expands.

  testPruneNondeterministicExpandsOutInFindCommands = {
    expr = let
      fragment = pruneNondeterministic "$out/packages";
    in
      lib.hasInfix "find $out/packages -maxdepth 2" fragment;
    expected = true;
  };

  testPruneNondeterministicExpandsOutInFinalRm = {
    expr = let
      fragment = pruneNondeterministic "$out/packages";
    in
      lib.hasInfix "rm -rf $out/packages/*/.lake/build/bin" fragment;
    expected = true;
  };

  testPruneNondeterministicOutIsShellExpandable = {
    # The load-bearing assertion: `$out` must never be wrapped in single
    # quotes anywhere in the fragment, because a shell never expands `$out`
    # inside single quotes. `lib.escapeShellArg "$out/packages"` would
    # produce `'$out/packages'`, which this specifically rejects.
    expr = let
      fragment = pruneNondeterministic "$out/packages";
    in
      !(lib.hasInfix "'$out" fragment) && !(lib.hasInfix "$out'" fragment);
    expected = true;
  };

  testPruneNondeterministicAssertionWouldCatchEscapeShellArgRegression = {
    # Prove the assertion above actually has discriminating power: rebuild
    # the fragment the way a regression using `lib.escapeShellArg` would,
    # and confirm the SAME check flags it. Without this, the two tests
    # above could both be vacuously true for reasons unrelated to quoting.
    expr = let
      packagesDir = "$out/packages";
      buggyFragment = ''
        find ${lib.escapeShellArg packagesDir} -maxdepth 2 -name .git -type d -exec rm -rf {} +
        rm -rf ${lib.escapeShellArg packagesDir}/*/.lake/build/bin
      '';
    in
      (lib.hasInfix "'$out" buggyFragment) && !(lib.hasInfix "'$out" (pruneNondeterministic packagesDir));
    expected = true;
  };
}
