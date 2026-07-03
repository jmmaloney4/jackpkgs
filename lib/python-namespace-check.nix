{lib}: let
  inherit (builtins) readDir pathExists path pathIsDirectory;
  inherit (lib) concatMap concatStringsSep filter hasSuffix mapAttrsToList;

  # Read immediate subdirectories of a path
  subdirs = dir:
    if !(pathExists dir)
    then []
    else
      filter (
        name: let
          entryType = (readDir dir).${name} or null;
        in
          entryType == "directory"
      ) (builtins.attrNames (readDir dir));

  # Check if a path has an __init__.py
  hasInitPy = dir: pathExists (dir + "/__init__.py");

  # Discover immediate package roots under a member's src/ directory.
  # Returns a list of { rootName = "org"; path = <src/org>; hasInit = bool; }
  discoverPackageRoots = srcDir:
    if !(pathExists srcDir)
    then []
    else
      builtins.map (name: {
        rootName = name;
        path = srcDir + "/${name}";
        hasInit = hasInitPy (srcDir + "/${name}");
      }) (subdirs srcDir);

  # Find shared namespace roots where some members have __init__.py
  # and others don't. Returns the root names that are inconsistent.
  # members is a list of { name = "pkg-a"; srcDir = <path>; }
  checkMembers = members: let
    # For each member, get its package roots
    memberRoots =
      map (
        member: {
          inherit (member) name;
          roots = discoverPackageRoots member.srcDir;
        }
      )
      members;

    # Collect all (rootName, hasInit, memberName) tuples
    allTuples =
      concatMap (
        mr:
          map (
            root: {
              inherit (mr) name;
              inherit (root) rootName hasInit;
            }
          )
          mr.roots
      )
      memberRoots;

    # Group by rootName
    grouped = lib.groupBy (t: t.rootName) allTuples;

    # Find roots where hasInit is inconsistent across members
    inconsistentRoots = filter (
      rootName: let
        entries = grouped.${rootName};
        hasInitValues = map (e: e.hasInit) entries;
        allHaveInit = lib.all (v: v) hasInitValues;
        noneHaveInit = lib.all (v: !v) hasInitValues;
      in
        !(allHaveInit || noneHaveInit)
    ) (builtins.attrNames grouped);
  in
    map (
      rootName: let
        entries = grouped.${rootName};
        withInit = filter (e: e.hasInit) entries;
        withoutInit = filter (e: !e.hasInit) entries;
      in {
        inherit rootName;
        withInit = map (e: e.name) withInit;
        withoutInit = map (e: e.name) withoutInit;
      }
    )
    inconsistentRoots;
in {
  inherit discoverPackageRoots checkMembers;
}
