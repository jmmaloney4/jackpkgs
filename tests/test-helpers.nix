{lib}: {
  # Access justfile helpers from the flake's lib.justfile
  # This ensures tests validate the actual API exposed to consumers
  justHelpers = lib.justfile;

  # Utility to strip trailing newline for easier comparison
  stripTrailingNewline = str:
    if lib.hasSuffix "\n" str
    then lib.removeSuffix "\n" str
    else str;

  # Utility to check if string has exact leading whitespace
  hasLeadingSpaces = count: str:
    lib.hasPrefix (lib.concatStrings (lib.genList (_: " ") count)) str;
}
