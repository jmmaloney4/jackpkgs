{lib}: let
  validateWorkspacePath = path:
    if lib.hasInfix ".." path
    then throw "Invalid workspace path '${path}': contains '..' (path traversal not allowed)"
    else if lib.hasPrefix "/" path
    then throw "Invalid workspace path '${path}': absolute paths not allowed"
    else if lib.hasInfix "\n" path
    then throw "Invalid workspace path: contains newline"
    else path;

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
in {
  inherit
    validateWorkspacePath
    expandWorkspaceGlob
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
