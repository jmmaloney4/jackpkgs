{lib}: let
  # Helper to build justfile recipes without indentation issues
  # Usage: mkRecipe "recipe-name" "comment" ["cmd1" "cmd2"]
  # Or with echoCommands: mkRecipe "recipe-name" "comment" ["cmd1" "cmd2"] true
  #
  # Supports shebang recipes: if the first command starts with #!, the recipe
  # will be treated as a shebang recipe by just, executing all lines as a single
  # script with the specified interpreter.
  #
  # echoCommands: When true, automatically adds "set -x" after "set -euo pipefail"
  # in bash shebang recipes to make commands print as they execute (useful for
  # debugging and visibility). Default: false
  #
  # Example shebang recipe with echoCommands:
  #   mkRecipe "script" "Run script" [
  #     "#!/usr/bin/env bash"
  #     "set -euo pipefail"
  #     "echo 'hello'"
  #   ] true
  # Generates:
  #   # Run script
  #   script:
  #       #!/usr/bin/env bash
  #       set -euo pipefail
  #       set -x
  #       echo 'hello'
  mkRecipe = name: comment: commands: echoCommands: let
    hasShebang = commands != [] && lib.hasPrefix "#!" (lib.head commands);
    isBashShebang = hasShebang && lib.hasInfix "bash" (lib.head commands);

    # If echoCommands is true and this is a bash shebang recipe, inject "set -x"
    # after "set -euo pipefail" (or similar set commands)
    processedCommands =
      if echoCommands && isBashShebang
      then let
        # Find the position after set -euo pipefail (or similar)
        findSetCommand = cmds: let
          indexed =
            lib.imap0 (i: cmd: {
              idx = i;
              cmd = cmd;
            })
            cmds;
          setCmd = lib.findFirst (x: lib.hasPrefix "set -" x.cmd) null indexed;
        in
          if setCmd != null
          then setCmd.idx
          else null;

        setIdx = findSetCommand commands;
      in
        if setIdx != null
        then
          (lib.take (setIdx + 1) commands)
          ++ ["set -x"]
          ++ (lib.drop (setIdx + 1) commands)
        else commands
      else commands;
  in
    lib.concatStringsSep "\n" (
      ["# ${comment}" "${name}:"]
      ++ map (cmd: "    ${cmd}") processedCommands
      ++ [""]
    );

  # Helper to build justfile recipes with parameters
  # Usage: mkRecipeWithParams "recipe-name" ["param1=\"default\"" "param2=\"\""] "comment" ["cmd1" "cmd2"]
  # Or with echoCommands: mkRecipeWithParams "recipe-name" [...] "comment" [...] true
  # Generates: recipe-name param1="default" param2="":
  #
  # Also supports shebang recipes - just include the shebang as the first command.
  # echoCommands: When true, adds "set -x" after "set -euo pipefail" in bash recipes
  mkRecipeWithParams = name: params: comment: commands: echoCommands: let
    paramStr = lib.concatStringsSep " " params;
    fullName =
      if params == []
      then name
      else "${name} ${paramStr}";
  in
    mkRecipe fullName comment commands echoCommands;

  # Helper for conditional recipe lines
  optionalLines = cond: lines:
    if cond
    then lines
    else [];
in {
  inherit mkRecipe mkRecipeWithParams optionalLines;
}
