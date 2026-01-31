{lib}: let
  inherit (lib) any concatMapStringsSep hasPrefix hasSuffix removePrefix;
in {
  /**
  Validate package-lock.json for hermetic Nix builds.

  Returns: { valid = bool; errors = [ { package; reason; suggestion; } ]; }

  Checks for:
  - Missing resolved/integrity fields (except workspace packages)
  - Git dependencies (git+https://, git+ssh://, git://)
  - File dependencies (file:, link:)
  - Non-registry URLs
  */
  validatePackageLock = lockfile: let
    packages = lockfile.packages or {};

    checkEntry = name: entry: let
      isWorkspace = hasPrefix "" name || hasPrefix "node_modules/" name;
      resolved = entry.resolved or "";
      hasIntegrity = entry ? integrity && entry.integrity != "";
    in
      if isWorkspace
      then null
      else if !hasIntegrity
      then {
        package = name;
        reason = "Missing integrity field";
        suggestion = "Regenerate lockfile with 'npm install'";
      }
      else if !entry ? resolved || resolved == ""
      then {
        package = name;
        reason = "Missing resolved field";
        suggestion = "Regenerate lockfile with 'npm install'";
      }
      else if hasPrefix "git+https://" resolved || hasPrefix "git+ssh://" resolved || hasPrefix "git://" resolved
      then {
        package = name;
        reason = "Git dependency detected (${resolved})";
        suggestion = "Replace with npm registry version or publish to a private registry";
      }
      else if hasPrefix "file:" resolved || hasPrefix "link:" resolved
      then {
        package = name;
        reason = "File or link dependency detected (${resolved})";
        suggestion = "Use npm workspaces or publish to registry";
      }
      else if hasPrefix "https://registry.npmjs.org/" resolved
      then null
      else if hasPrefix "http://" resolved || hasPrefix "https://" resolved
      then {
        package = name;
        reason = "Non-registry dependency (${resolved})";
        suggestion = "Configure importNpmLockOptions.fetcherOpts for private registry";
      }
      else null;

    errors = lib.filter (x: x != null) (
      lib.mapAttrsToList (name: entry: checkEntry name entry) packages
    );
  in {
    valid = errors == [];
    inherit errors;
  };

  /**
  Format validation errors for user display.

  Returns: multi-line error string with actionable guidance.

  Example output:
  Hermetic npm dependency build validation failed for /path/to/package-lock.json

  The following dependencies are incompatible with hermetic Nix builds:

  Package: @myorg/private-lib
  Reason: Git dependency detected (git+https://github.com/...)
  Suggestion: Replace with npm registry version or publish to a private registry

  See ADR-022 and README for supported dependency forms.
  */
  formatValidationErrors = errors: lockfilePath: let
    formatSingle = err: ''
      Package: ${err.package}
      Reason: ${err.reason}
      Suggestion: ${err.suggestion}
    '';
  in ''
    Hermetic npm dependency build validation failed for ${lockfilePath}

    The following dependencies are incompatible with hermetic Nix builds:

    ${concatMapStringsSep "\n" formatSingle errors}

    See ADR-022 and README (Hermetic Constraints section) for supported dependency forms.
  '';

  /**
  Check single package entry for hermetic issues.

  Returns: null | { package; reason; suggestion; }

  This is a lower-level function used by validatePackageLock.
  Exposed separately for advanced use cases.
  */
  checkPackageEntry = name: entry: let
    isWorkspace = hasPrefix "" name || hasPrefix "node_modules/" name;
    resolved = entry.resolved or "";
    hasIntegrity = entry ? integrity && entry.integrity != "";
  in
    if isWorkspace
    then null
    else if !hasIntegrity
    then {
      package = name;
      reason = "Missing integrity field";
      suggestion = "Regenerate lockfile with 'npm install'";
    }
    else if !entry ? resolved || resolved == ""
    then {
      package = name;
      reason = "Missing resolved field";
      suggestion = "Regenerate lockfile with 'npm install'";
    }
    else if hasPrefix "git+https://" resolved || hasPrefix "git+ssh://" resolved || hasPrefix "git://" resolved
    then {
      package = name;
      reason = "Git dependency detected (${resolved})";
      suggestion = "Replace with npm registry version or publish to a private registry";
    }
    else if hasPrefix "file:" resolved || hasPrefix "link:" resolved
    then {
      package = name;
      reason = "File or link dependency detected (${resolved})";
      suggestion = "Use npm workspaces or publish to registry";
    }
    else if hasPrefix "https://registry.npmjs.org/" resolved
    then null
    else if hasPrefix "http://" resolved || hasPrefix "https://" resolved
    then {
      package = name;
      reason = "Non-registry dependency (${resolved})";
      suggestion = "Configure importNpmLockOptions.fetcherOpts for private registry";
    }
    else null;
}
