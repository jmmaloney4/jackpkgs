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
      lib.mapAttrsToList
        (var: value:
          if builtins.match "[a-zA-Z_][a-zA-Z0-9_]*" var == null
          then throw "mkShellEnvHook: invalid shell variable name '${var}'"
          else "export ${var}=${lib.escapeShellArg (toString value)}")
        (lib.filterAttrs (_: v: v != null) env)
    )
  )
)
