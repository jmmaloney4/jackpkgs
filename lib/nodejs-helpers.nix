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
      # The generated shell removes link destinations before creating them, so
      # an empty segment would turn `rm -rf <pkg>/node_modules` into an
      # absolute `/node_modules`.  Reject it at evaluation time instead.
      (p:
        if p == ""
        then throw "Invalid workspace path: empty string"
        else p)
    ];

  validatePackageName = name:
    lib.pipe name [
      (assertNotContains ".." "Invalid package name '${name}': contains '..' (path traversal not allowed)")
      (assertNotContains "\n" "Invalid package name '${name}': contains newline")
      # Same reasoning as validateWorkspacePath: an empty name would make the
      # destination `node_modules/` itself.
      (n:
        if n == ""
        then throw "Invalid package name: empty string"
        else n)
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
  # Shell link primitives
  # ---------------------------------------------------------------------------

  # `ln -sfn <target> <dest>` does not replace <dest> when <dest> is a real
  # directory: ln resolves it as a destination *directory* and creates
  # <dest>/<basename target> instead.  In a workspace where someone has run
  # `pnpm install` — which materializes real per-package node_modules
  # directories — that produced `<pkg>/node_modules/node_modules -> /nix/store/...`,
  # so the pinned dependency tree was silently ignored and tools resolved
  # whatever local pnpm state happened to be on disk.
  #
  # GNU coreutils has `ln -sfnT` for exactly this, but these scripts also run on
  # darwin, so the destination is removed explicitly instead.
  #
  # jackpkgs_link intentionally clobbers a real directory: the whole point of
  # the runtime is that dependency resolution comes from the pinned tree, and a
  # loud-but-fatal alternative would break every working copy that has run
  # `pnpm install`.  It prints a notice when it does, since the developer loses
  # their local install and needs `pnpm install` to get it back.  The notice is
  # self-limiting — after the first run the destination is a symlink.
  #
  # Emitted by both mkWorkspaceSymlinks and mkWorkspaceRuntime; redefining the
  # functions when both are used in one script is harmless.
  # Every path argument is passed after `--` so a destination that begins with
  # `-` (a package directory named `-foo`, say) is treated as an operand rather
  # than as an option bundle.  The eval-time validators do not reject a leading
  # hyphen, so this is the layer that makes it harmless.
  linkHelpers = ''
    jackpkgs_link() {
      if [ -d "$2" ] && [ ! -L "$2" ]; then
        echo "jackpkgs: replacing real directory $2 with a link into the pinned dependency tree (re-run 'pnpm install' to restore a local install)" >&2
      fi
      rm -rf -- "$2"
      ln -s -- "$1" "$2"
    }

    # Scope directories (node_modules/@foo) must be real directories we can
    # write into.  A leftover symlink from a previous layout would point at a
    # read-only store path, so replace it rather than link into it.
    jackpkgs_ensure_dir() {
      if [ -L "$1" ]; then
        rm -f -- "$1"
      fi
      mkdir -p -- "$1"
    }
  '';

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
  #   2. Emit `jackpkgs_ensure_dir node_modules/@scope` when scoped.
  #   3. Emit `jackpkgs_link $(pwd)/<pkg> node_modules/<name>`.
  #
  # NOTE: workspaceRoot must be a Nix store path (e.g. inputs.self.outPath).
  # builtins.readFile is called at evaluation time against the store copy,
  # not against the mutable workspace.  This is intentional: the source is
  # added to the store via `self` before evaluation, so the read is pure
  # within a given evaluation.
  mkWorkspaceSymlinks = workspaceRoot: packages:
    linkHelpers
    + lib.concatMapStringsSep "\n" (pkg: let
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
        lib.optionalString isScoped "jackpkgs_ensure_dir node_modules/${lib.escapeShellArg scope}\n"
        + "jackpkgs_link \"\$(pwd)/${lib.escapeShellArg (validateWorkspacePath pkg)}\" node_modules/${lib.escapeShellArg pkgName}")
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

    mkWorkspaceRuntime = {
      nodeModules,
      workspaceRoot,
      packages,
    }: ''
      ${linkHelpers}
      nm_store="${nodeModules}"
      nm_root="$nm_store/node_modules"
      if [ ! -d "$nm_root" ]; then
        echo "ERROR: Unable to find node_modules in $nm_store" >&2
        echo "Expected: node_modules/ at the derivation root" >&2
        exit 1
      fi

      jackpkgs_ensure_dir node_modules
      shopt -s dotglob nullglob
      for entry in "$nm_root"/*/; do
        entry_name="$(basename "$entry")"
        if [[ "$entry_name" == @* ]]; then
          jackpkgs_ensure_dir "node_modules/$entry_name"
          for scoped_pkg in "$entry"*/; do
            jackpkgs_link "''${scoped_pkg%/}" "node_modules/$entry_name/$(basename "$scoped_pkg")"
          done
        else
          jackpkgs_link "''${entry%/}" "node_modules/$entry_name"
        fi
      done
      shopt -u dotglob nullglob

      ${lib.concatMapStringsSep "\n" (rawPkg: let
          pkg = lib.escapeShellArg (validateWorkspacePath rawPkg);
        in ''
          mkdir -p -- ${pkg}
          if [ -d "$nm_store"/${pkg}/node_modules ]; then
            jackpkgs_link "$nm_store"/${pkg}/node_modules ${pkg}/node_modules
          elif [ -d "$nm_root"/${pkg}/node_modules ]; then
            jackpkgs_link "$nm_root"/${pkg}/node_modules ${pkg}/node_modules
          fi
        '')
        packages}

      ${mkWorkspaceSymlinks workspaceRoot packages}

      nm_bin="$nm_store/node_modules/.bin"
      if [ -d "$nm_bin" ]; then
        export PATH="$nm_bin:$PATH"
      fi
    '';
  };
}
