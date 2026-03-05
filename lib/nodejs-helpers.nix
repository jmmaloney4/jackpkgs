{lib}: let
  # ---------------------------------------------------------------------------
  # Validation helpers
  # ---------------------------------------------------------------------------
  # Private primitive: throw if `needle` is found in `s`, otherwise return `s`.
  # Used to compose validateWorkspacePath and validatePackageName without
  # repeating the hasInfix pattern for every checked substring.
  assertNotContains = needle: msg: s:
    if lib.hasInfix needle s
    then throw msg
    else s;

  validateWorkspacePath = path:
    lib.pipe path [
      (assertNotContains ".." "Invalid workspace path '${path}': contains '..' (path traversal not allowed)")
      (assertNotContains "\n" "Invalid workspace path '${path}': contains newline")
      (p:
        if lib.hasPrefix "/" p
        then throw "Invalid workspace path '${path}': absolute paths not allowed"
        else p)
    ];

  validatePackageName = name:
    lib.pipe name [
      (assertNotContains ".." "Invalid package name '${name}': contains '..' (path traversal not allowed)")
      (assertNotContains "\n" "Invalid package name '${name}': contains newline")
    ];

  # ---------------------------------------------------------------------------
  # Workspace glob expansion
  # ---------------------------------------------------------------------------

  # Expand a single workspace glob pattern relative to workspaceRoot.
  #
  # Supported patterns:
  #   "dir/*"     - expands to all immediate subdirectories of dir/
  #   "some/path" - returned as-is (treated as a literal package path)
  #
  # Not supported:
  #   "**"        - recursive globs are rejected with a clear error
  #
  # NOTE: workspaceRoot must be a path already present in the Nix store
  # (e.g. inputs.self.outPath) or a local path accessible at evaluation
  # time.  Callers are responsible for providing a store-resident root so
  # that builtins.readDir does not introduce unintentional impurity.
  expandWorkspaceGlob = workspaceRoot: glob: let
    validatedGlob = validateWorkspacePath glob;
  in
    if lib.hasInfix "**" validatedGlob
    then throw "Recursive globs (**) not supported in workspace patterns (got '${validatedGlob}' under ${toString workspaceRoot}). Use explicit paths or 'dir/*' patterns."
    else if lib.hasSuffix "/*" validatedGlob
    then let
      dir = lib.removeSuffix "/*" validatedGlob;
      fullPath = workspaceRoot + "/${dir}";
      entries =
        if builtins.pathExists fullPath
        then builtins.readDir fullPath
        else {};
      subdirs = lib.filterAttrs (name: type: type == "directory" && name != "." && name != "..") entries;
    in
      map (name: "${dir}/${name}") (lib.attrNames subdirs)
    else [validatedGlob];

  # ---------------------------------------------------------------------------
  # Workspace symlink generation
  # ---------------------------------------------------------------------------

  # Generate a shell snippet that creates node_modules symlinks for each
  # workspace package so tools like tsc and biome can resolve cross-package
  # imports.
  #
  # For each package in `packages`:
  #   1. Read package.json from workspaceRoot/<pkg>/package.json to get the
  #      package name (supports @scope/name scoped packages).
  #   2. Emit `mkdir -p node_modules/@scope` when scoped.
  #   3. Emit `ln -sfn $(pwd)/<pkg> node_modules/<name>`.
  #
  # NOTE: workspaceRoot must be a Nix store path (e.g. inputs.self.outPath).
  # builtins.readFile is called at evaluation time against the store copy,
  # not against the mutable workspace.  This is intentional: the source is
  # added to the store via `self` before evaluation, so the read is pure
  # within a given evaluation.
  mkWorkspaceSymlinks = workspaceRoot: packages:
    lib.concatMapStringsSep "\n" (pkg: let
      pkgJsonPath = workspaceRoot + "/${pkg}/package.json";
      rawPkgName =
        if builtins.pathExists pkgJsonPath
        then (builtins.fromJSON (builtins.readFile pkgJsonPath)).name
        else null;
      pkgName =
        if rawPkgName != null
        then validatePackageName rawPkgName
        else null;
      nameparts = lib.optionals (pkgName != null) (lib.splitString "/" pkgName);
      isScoped = pkgName != null && lib.hasPrefix "@" pkgName && builtins.length nameparts == 2;
      scope = lib.optionalString isScoped (builtins.elemAt nameparts 0);
    in
      if pkgName == null
      then "# Skipping workspace symlink for ${pkg}: package.json not found"
      else
        lib.optionalString isScoped "mkdir -p node_modules/${lib.escapeShellArg scope}\n"
        + "ln -sfn $(pwd)/${lib.escapeShellArg pkg} node_modules/${lib.escapeShellArg pkgName}")
    packages;

  # ---------------------------------------------------------------------------
  # pnpm workspace discovery
  # ---------------------------------------------------------------------------

  # Discover pnpm workspace packages from pnpm-workspace.yaml (or .yml).
  #
  # `fromYAML` is a caller-supplied function :: path -> attrset that parses
  # YAML.  It is kept as an argument here (rather than hard-coding yq-go IFD)
  # so that callers can inject a test double or a pre-parsed JSON sidecar
  # during evaluation without triggering IFD.
  #
  # expandWorkspaceGlob is called directly (no jackpkgsLib indirection needed)
  # because all helpers live in the same file.
  discoverPnpmPackages = {
    workspaceRoot,
    fromYAML,
  }: let
    yamlPathYaml = workspaceRoot + "/pnpm-workspace.yaml";
    yamlPathYml = workspaceRoot + "/pnpm-workspace.yml";
    yamlPath =
      if builtins.pathExists yamlPathYaml
      then yamlPathYaml
      else if builtins.pathExists yamlPathYml
      then yamlPathYml
      else null;
    yamlExists = yamlPath != null;
    workspaceYaml =
      if yamlExists
      then fromYAML yamlPath
      else {};
    patterns = workspaceYaml.packages or [];
    workspaceGlobs =
      if builtins.isList patterns
      then patterns
      else [];
    negationPatterns = lib.filter (p: lib.hasPrefix "!" p) workspaceGlobs;
    validatedWorkspaceGlob =
      if negationPatterns != []
      then throw "Negation workspace patterns are not supported in jackpkgs auto-discovery yet: ${lib.concatStringsSep ", " negationPatterns}. Use explicit packages option."
      else workspaceGlobs;
    # expandWorkspaceGlob called directly — no jackpkgsLib self-reference needed
    allPackages = lib.flatten (map (expandWorkspaceGlob workspaceRoot) validatedWorkspaceGlob);
    hasPackageJson = p: builtins.pathExists (workspaceRoot + "/${p}/package.json");
  in
    if yamlExists
    then lib.filter hasPackageJson allPackages
    else [];
in {
  inherit
    validateWorkspacePath
    validatePackageName
    expandWorkspaceGlob
    mkWorkspaceSymlinks
    discoverPnpmPackages
    ;

  nodejs = {
    findNodeModulesBin = pathVar: storePath: ''
      ${pathVar}="${storePath}/node_modules/.bin"
    '';

    findNodeModulesRoot = rootVar: storePath: ''
      ${rootVar}="${storePath}/node_modules"
    '';
  };
}
