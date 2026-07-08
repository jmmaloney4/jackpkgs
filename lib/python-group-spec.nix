# Pure combinators for computing a uv2nix virtual-env dependency spec from a
# jackpkgs environment's group-selection options. Kept free of any uv2nix
# workspace value so the logic is unit-testable against synthetic `deps`
# attrsets (see tests/python-group-spec.nix). Wired into the real workspace by
# modules/flake-parts/python.nix.
#
# The two inputs mirror uv2nix `workspace.deps`:
#   depsDefault :: { <member> = [ <default-group> ... ]; }   (production)
#   depsGroups  :: { <member> = [ <defined-group> ... ]; }   (all groups defined)
# A "spec" has the same shape: { <member> = [ <group> ... ]; }.
{lib}: let
  inherit (lib) isList unique concatLists attrValues intersectLists mapAttrs subtractLists mapAttrsToList concatStringsSep;

  # Every group name defined by any member — the validation source of truth.
  allGroupNames = depsGroups: unique (concatLists (attrValues depsGroups));

  # Resolve `includeGroups` (bool | [str]) into a spec. An explicit env `spec`
  # is handled by the caller and never reaches here.
  #   true      -> all defined groups per member
  #   false     -> production (default-groups per member)
  #   [ names ] -> per member: default-groups ∪ (names the member defines)
  resolveSpec = {
    depsDefault,
    depsGroups,
    includeGroups ? false,
  }:
    if includeGroups == true
    then depsGroups
    else if isList includeGroups
    then
      mapAttrs (
        name: memberGroups:
          unique ((depsDefault.${name} or []) ++ intersectLists includeGroups memberGroups)
      )
      depsGroups
    else depsDefault;

  # Merge per-member `groups` ONTO an already-resolved spec (computed OR
  # explicit). Union so it is idempotent with whatever includeGroups added.
  composeGroups = {
    spec,
    groups ? {},
  }:
    spec
    // mapAttrs (
      member: addGroups:
        unique ((spec.${member} or []) ++ addGroups)
    )
    groups;

  # Throw with context if any requested group name is undefined. Returns the
  # supplied `payload` unchanged on success so callers can thread it inline
  # (`validateGroupSelection { ...; payload = spec; }`).
  #   includeGroups list entries must be defined by SOME member (workspace-wide).
  #   `groups` keys must be members, and each value a group THAT member defines.
  validateGroupSelection = {
    depsGroups,
    includeGroups ? null,
    groups ? {},
    label ? "jackpkgs.python",
    payload ? null,
  }: let
    known = allGroupNames depsGroups;
    unknownInclude =
      if isList includeGroups
      then subtractLists known includeGroups
      else [];
    includeErrors =
      lib.optional (unknownInclude != [])
      "${label}: includeGroups references unknown group(s): ${concatStringsSep ", " unknownInclude}. Defined groups: ${concatStringsSep ", " known}.";
    memberErrors = concatLists (mapAttrsToList (
        member: gs:
          if !(depsGroups ? ${member})
          then ["${label}: groups.\"${member}\" is not a workspace member. Members: ${concatStringsSep ", " (lib.attrNames depsGroups)}."]
          else
            map (
              g: "${label}: groups.\"${member}\" references group \"${g}\" which the member does not define. It defines: ${concatStringsSep ", " depsGroups.${member}}."
            ) (subtractLists depsGroups.${member} gs)
      )
      groups);
    errors = includeErrors ++ memberErrors;
  in
    if errors == []
    then payload
    else throw (concatStringsSep "\n" errors);
in {
  inherit allGroupNames resolveSpec composeGroups validateGroupSelection;
}
