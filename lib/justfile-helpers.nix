{lib}: let
  # Helper to build justfile recipes without indentation issues
  # Usage: mkRecipe "recipe-name" "comment" ["cmd1" "cmd2"]
  #
  # Supports shebang recipes: if the first command starts with #!, the recipe
  # will be treated as a shebang recipe by just, executing all lines as a single
  # script with the specified interpreter.
  #
  # Example shebang recipe:
  #   mkRecipe "script" "Run script" [
  #     "#!/usr/bin/env bash"
  #     "set -euo pipefail"
  #     "echo 'hello'"
  #   ]
  # Generates:
  #   # Run script
  #   script:
  #       #!/usr/bin/env bash
  #       set -euo pipefail
  #       echo 'hello'
  mkRecipe = name: comment: commands: let
    hasShebang = commands != [] && lib.hasPrefix "#!" (lib.head commands);
  in
    lib.concatStringsSep "\n" (
      ["# ${comment}" "${name}:"]
      ++ map (cmd: "    ${cmd}") commands
      ++ [""]
    );

  # Helper to build justfile recipes with parameters
  # Usage: mkRecipeWithParams "recipe-name" ["param1=\"default\"" "param2=\"\""] "comment" ["cmd1" "cmd2"]
  # Generates: recipe-name param1="default" param2="":
  #
  # Also supports shebang recipes - just include the shebang as the first command.
  mkRecipeWithParams = name: params: comment: commands: let
    paramStr = lib.concatStringsSep " " params;
    fullName =
      if params == []
      then name
      else "${name} ${paramStr}";
  in
    mkRecipe fullName comment commands;

  # Helper for conditional recipe lines
  optionalLines = cond: lines:
    if cond
    then lines
    else [];
in {
  inherit mkRecipe mkRecipeWithParams optionalLines;
}
