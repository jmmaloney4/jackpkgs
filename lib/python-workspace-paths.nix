{lib}: let
  # Reuse the well-tested workspace primitives from nodejs-helpers.nix.
  # expandWorkspaceGlob handles "dir/*" expansion and rejects "**" recursion.
  # validateWorkspacePath guards against path traversal.
  nodejsHelpers = import ./nodejs-helpers.nix {inherit lib;};
  inherit (nodejsHelpers) expandWorkspaceGlob validateWorkspacePath;

  inherit (builtins) fromTOML readFile pathExists;
  inherit (lib) flatten filter any hasPrefix unique;

  /**
  Check whether a member path matches any exclude entry.

  An exclude entry matches if it is identical to the member or if the
  member is nested beneath it (e.g. exclude "tools/spike" matches
  "tools/spike/sub").  Non-recursive excludes must match exactly.

  Parameters
  ----------
  excludes : list of str
      Exclude patterns from `[tool.uv.workspace].exclude`.
  member : str
      Workspace-relative member path to test.

  Returns
  -------
  bool
      True when the member should be excluded.
  */
  isExcluded = excludes: member:
    any (ex: member == ex || hasPrefix "${ex}/" member) excludes;

  /**
  Discover validated Python workspace members from a pyproject.toml.

  Reads `[tool.uv.workspace].members`, expands glob patterns
  (`dir/*`), applies the `exclude` list, and validates that each
  resolved directory contains its own `pyproject.toml`.

  This is the single source of truth for "which directories are
  Python workspace packages" and should replace hand-maintained
  member lists in pytest, mypy, and ty configuration (ADR-041).

  Parameters
  ----------
  workspaceRoot : path
      Path to the workspace root (typically `inputs.self.outPath` or a
      Nix store path).  Must be accessible at evaluation time.
  pyprojectPath : path
      Path to the root `pyproject.toml` containing the
      `[tool.uv.workspace]` table.

  Returns
  -------
  list of str
      Validated workspace-relative member paths, each confirmed to
      contain a `pyproject.toml`.
  */
  discoverPythonWorkspaceMembers = {
    workspaceRoot,
    pyprojectPath,
  }: let
    pyproject = fromTOML (readFile pyprojectPath);
    memberSpecs = pyproject.tool.uv.workspace.members or ["."];
    excludes = pyproject.tool.uv.workspace.exclude or [];

    # Expand all glob patterns into concrete member paths.
    allMembers = unique (flatten (map (expandWorkspaceGlob workspaceRoot) memberSpecs));

    # Apply the exclude list.
    afterExclude = filter (m: !(isExcluded excludes m)) allMembers;

    # Validate each member is a real Python package (has pyproject.toml).
    hasPyproject = member: pathExists (workspaceRoot + "/${member}/pyproject.toml");
  in
    filter hasPyproject afterExclude;

  /**
  Map a workspace member to its Python source root.

  Convention: `<member>/src`.  Non-standard layouts are handled via
  the `sourceRootMap` override or by returning `null` so the caller
  can decide whether to skip or fail.

  Parameters
  ----------
  workspaceRoot : path
      Path to the workspace root.
  member : str
      Workspace-relative member path.
  sourceRootMap : attrset
      Optional overrides mapping member paths to custom source roots,
      e.g. `{ "libs/legacy" = "libs/legacy/python"; }`.
  strict : bool
      When true, throw a descriptive error if no source root is found.
      When false (default), return null for members without a source
      root.

  Returns
  -------
  str or null
      Source root path relative to workspaceRoot, or null when the
      member has no `src/` and no override (and strict is false).
  */
  memberSrcPath = {
    workspaceRoot,
    member,
    sourceRootMap ? {},
    strict ? false,
  }: let
    overrideCandidate = sourceRootMap.${member} or null;
    override =
      if overrideCandidate == null
      then null
      else validateWorkspacePath overrideCandidate;
  in
    if override != null
    then
      if pathExists (workspaceRoot + "/${override}")
      then override
      else if strict
      then throw "python-workspace-paths: member '${member}' override '${override}' does not exist under the workspace root."
      else null
    else let
      defaultSrc =
        if member == "."
        then "src"
        else "${member}/src";
    in
      if pathExists (workspaceRoot + "/${defaultSrc}")
      then defaultSrc
      else if strict
      then throw "python-workspace-paths: member '${member}' has no source root (no ${member}/src/ and no sourceRootMap override). Set sourceRootMap.\"${member}\" to the correct path or remove the member from the workspace."
      else null;

  /**
  Derive Python source-root paths for all workspace members.

  Combines `discoverPythonWorkspaceMembers` and `memberSrcPath` into
  a single call.  The returned list is the input for pytest
  `pythonpath`, mypy `mypy_path`, and ty `extra-paths` — eliminating
  the drift that occurs when these lists are maintained separately
  (ADR-041).

  Parameters
  ----------
  workspaceRoot : path
      Path to the workspace root.
  pyprojectPath : path
      Path to the root `pyproject.toml`.
  sourceRootMap : attrset, optional
      Overrides for non-standard source layouts.
  strict : bool, optional
      When true, fail if any validated member lacks a source root.
      When false (default), members without source roots are silently
      omitted — suitable for repos with mixed src/flat layouts.

  Returns
  -------
  list of str
      Source-root paths relative to workspaceRoot.
  */
  pythonWorkspaceSrcPaths = {
    workspaceRoot,
    pyprojectPath,
    sourceRootMap ? {},
    strict ? false,
  }: let
    members = discoverPythonWorkspaceMembers {
      inherit workspaceRoot pyprojectPath;
    };
    srcPaths = map (member:
      memberSrcPath {
        inherit workspaceRoot member sourceRootMap strict;
      })
    members;
  in
    filter (p: p != null) srcPaths;
in {
  inherit
    discoverPythonWorkspaceMembers
    memberSrcPath
    pythonWorkspaceSrcPaths
    ;
}
