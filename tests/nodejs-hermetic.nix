{
  lib,
  testHelpers,
}: let
  nodejsLib = import ../lib/nodejs.nix {inherit lib;};

  # Helper to load fixture lockfile
  loadLockfile = fixture:
    builtins.fromJSON (builtins.readFile (./fixtures/nodejs + "/${fixture}/package-lock.json"));
in {
  # Valid hermetic lockfile passes validation
  testHermeticValid = {
    expr = let
      lockfile = loadLockfile "hermetic-valid";
      validation = nodejsLib.validatePackageLock lockfile;
    in
      validation.valid;
    expected = true;
  };

  # Valid hermetic lockfile has no errors
  testHermeticValidNoErrors = {
    expr = let
      lockfile = loadLockfile "hermetic-valid";
      validation = nodejsLib.validatePackageLock lockfile;
    in
      builtins.length validation.errors;
    expected = 0;
  };

  # Git dependency detected and rejected
  testGitDependencyRejected = {
    expr = let
      lockfile = loadLockfile "hermetic-git-dep";
      validation = nodejsLib.validatePackageLock lockfile;
    in
      validation.valid;
    expected = false;
  };

  # Git dependency produces error with package name
  testGitDependencyErrorHasPackageName = {
    expr = let
      lockfile = loadLockfile "hermetic-git-dep";
      validation = nodejsLib.validatePackageLock lockfile;
      firstError = builtins.head validation.errors;
    in
      firstError.package;
    expected = "some-git-dep";
  };

  # Git dependency error message contains "git"
  testGitDependencyErrorMessage = {
    expr = let
      lockfile = loadLockfile "hermetic-git-dep";
      validation = nodejsLib.validatePackageLock lockfile;
      firstError = builtins.head validation.errors;
    in
      builtins.match ".*git.*" firstError.reason != null;
    expected = true;
  };

  # File dependency detected and rejected
  testFileDependencyRejected = {
    expr = let
      lockfile = loadLockfile "hermetic-file-dep";
      validation = nodejsLib.validatePackageLock lockfile;
    in
      validation.valid;
    expected = false;
  };

  # File dependency produces error with package name
  testFileDependencyErrorHasPackageName = {
    expr = let
      lockfile = loadLockfile "hermetic-file-dep";
      validation = nodejsLib.validatePackageLock lockfile;
      firstError = builtins.head validation.errors;
    in
      firstError.package;
    expected = "some-local-dep";
  };

  # File dependency error message contains "file"
  testFileDependencyErrorMessage = {
    expr = let
      lockfile = loadLockfile "hermetic-file-dep";
      validation = nodejsLib.validatePackageLock lockfile;
      firstError = builtins.head validation.errors;
    in
      builtins.match ".*[Ff]ile.*" firstError.reason != null;
    expected = true;
  };

  # Missing integrity detected and rejected
  testMissingIntegrityRejected = {
    expr = let
      lockfile = loadLockfile "hermetic-missing-integrity";
      validation = nodejsLib.validatePackageLock lockfile;
    in
      validation.valid;
    expected = false;
  };

  # Missing integrity error message is helpful
  testMissingIntegrityErrorMessage = {
    expr = let
      lockfile = loadLockfile "hermetic-missing-integrity";
      validation = nodejsLib.validatePackageLock lockfile;
      firstError = builtins.head validation.errors;
    in
      firstError.reason;
    expected = "Missing integrity field";
  };

  # Error message format includes lockfile path
  testErrorFormatIncludesLockfile = {
    expr = let
      lockfile = loadLockfile "hermetic-git-dep";
      validation = nodejsLib.validatePackageLock lockfile;
      formatted = nodejsLib.formatValidationErrors validation.errors "./package-lock.json";
    in
      builtins.match ".*package-lock.json.*" formatted != null;
    expected = true;
  };

  # Error message format includes package name
  testErrorFormatIncludesPackageName = {
    expr = let
      lockfile = loadLockfile "hermetic-git-dep";
      validation = nodejsLib.validatePackageLock lockfile;
      formatted = nodejsLib.formatValidationErrors validation.errors "./package-lock.json";
    in
      builtins.match ".*some-git-dep.*" formatted != null;
    expected = true;
  };

  # Error message format includes ADR reference
  testErrorFormatIncludesADR = {
    expr = let
      lockfile = loadLockfile "hermetic-git-dep";
      validation = nodejsLib.validatePackageLock lockfile;
      formatted = nodejsLib.formatValidationErrors validation.errors "./package-lock.json";
    in
      builtins.match ".*ADR-022.*" formatted != null;
    expected = true;
  };

  # Error message format includes "Hermetic npm dependency build"
  testErrorFormatIncludesHeader = {
    expr = let
      lockfile = loadLockfile "hermetic-git-dep";
      validation = nodejsLib.validatePackageLock lockfile;
      formatted = nodejsLib.formatValidationErrors validation.errors "./package-lock.json";
    in
      builtins.match ".*Hermetic npm dependency build validation failed.*" formatted != null;
    expected = true;
  };

  # Multiple errors are collected
  testMultipleErrorsCollected = {
    expr = let
      lockfile = loadLockfile "hermetic-git-dep";
      validation = nodejsLib.validatePackageLock lockfile;
    in
      builtins.length validation.errors > 0;
    expected = true;
  };

  # Suggestion field is present in errors
  testErrorHasSuggestion = {
    expr = let
      lockfile = loadLockfile "hermetic-git-dep";
      validation = nodejsLib.validatePackageLock lockfile;
      firstError = builtins.head validation.errors;
    in
      firstError ? suggestion && firstError.suggestion != "";
    expected = true;
  };
}
