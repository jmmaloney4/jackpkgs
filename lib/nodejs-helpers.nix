{lib}: let
  validateWorkspacePath = path:
    if lib.hasInfix ".." path
    then throw "Invalid workspace path '${path}': contains '..' (path traversal not allowed)"
    else if lib.hasPrefix "/" path
    then throw "Invalid workspace path '${path}': absolute paths not allowed"
    else if lib.hasInfix "\n" path
    then throw "Invalid workspace path: contains newline"
    else path;

  validatePackageName = name:
    if lib.hasInfix ".." name
    then throw "Invalid package name '${name}': contains '..' (path traversal not allowed)"
    else if lib.hasInfix "\n" name
    then throw "Invalid package name: contains newline"
    else name;

  expandWorkspaceGlob = workspaceRoot: glob: let
    validatedGlob = validateWorkspacePath glob;
  in
    if lib.hasInfix "**" validatedGlob
    then throw "Recursive globs (**) not supported in workspace patterns. Use explicit paths or 'dir/*' patterns."
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
        lib.optionalString isScoped "mkdir -p node_modules/${lib.escapeShellArg scope}"
        + "\nln -sfn \"$(pwd)/${lib.escapeShellArg pkg}\" node_modules/${lib.escapeShellArg pkgName}")
    packages;

  discoverPnpmPackages = {
    workspaceRoot,
    fromYAML,
    jackpkgsLib,
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
    allPackages = lib.flatten (map (jackpkgsLib.expandWorkspaceGlob workspaceRoot) validatedWorkspaceGlob);
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
