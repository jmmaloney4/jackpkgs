{lib}: {
  # Helper to import the mkRecipe and optionalLines functions from just.nix
  # We extract them from the module's let binding
  justHelpers = let
    # The helpers are defined in the let binding at the top of the module
    mkRecipe = name: comment: commands:
      lib.concatStringsSep "\n" (
        ["# ${comment}" "${name}:"]
        ++ map (cmd: "    ${cmd}") commands
        ++ [""]
      );

    # Helper to build justfile recipes with parameters
    mkRecipeWithParams = name: params: comment: commands: let
      paramStr = lib.concatStringsSep " " params;
      fullName =
        if params == []
        then name
        else "${name} ${paramStr}";
    in
      mkRecipe fullName comment commands;

    optionalLines = cond: lines:
      if cond
      then lines
      else [];
  in {
    inherit mkRecipe mkRecipeWithParams optionalLines;
  };

  # Utility to strip trailing newline for easier comparison
  stripTrailingNewline = str:
    if lib.hasSuffix "\n" str
    then lib.removeSuffix "\n" str
    else str;

  # Utility to check if string has exact leading whitespace
  hasLeadingSpaces = count: str:
    lib.hasPrefix (lib.concatStrings (lib.genList (_: " ") count)) str;
}
