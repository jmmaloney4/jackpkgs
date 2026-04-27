{
  lib,
  pkgs,
}: {
  name,
  env,
}:
pkgs.makeSetupHook {inherit name;} (
  pkgs.writeText "${name}.sh" (
    lib.concatStringsSep "\n" (
      lib.mapAttrsToList (
        var: value:
        # Use double-quoting so shell variables like $HOME expand at runtime.
        # Escape internal double-quotes and backslashes in the Nix value.
        let
          escaped = lib.strings.escape ["\\" "\""] (toString value);
        in "export ${var}=\"${escaped}\""
      )
      env
    )
  )
)
