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
      lib.mapAttrsToList (var: value: "export ${var}=${lib.escapeShellArg (toString value)}") (lib.filterAttrs (_: v: v != null) env)
    )
  )
)
