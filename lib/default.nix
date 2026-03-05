{pkgs}:
with pkgs.lib; rec {
  # Add your library functions here

  # Justfile generation helpers
  # These helpers make it easy to generate justfile content without indentation issues
  justfile = import ./justfile-helpers.nix {lib = pkgs.lib;};

  /**
  Build a YAML-to-Nix parser backed by yq-go IFD with an optional JSON
  sidecar optimisation.

  Returns a function `fromYAML :: path -> attrset` suitable for passing to
  `discoverPnpmPackages` and other helpers that need to read YAML at
  evaluation time.

  The `jsonSidecar` flag (default: true) enables the fast path: if a
  pre-generated `.json` file exists adjacent to the `.yaml`/`.yml` file it
  is read with `builtins.fromJSON` and no derivation is built.  When false
  (or when the sidecar is absent) a `pkgs.runCommand` derivation invoking
  `yq -o=json` is used instead.

  Example:

  ```nix
  let fromYAML = jackpkgsLib.mkFromYAML { jsonSidecar = true; };
  in jackpkgsLib.discoverPnpmPackages { inherit workspaceRoot fromYAML; }
  ```
  */
  mkFromYAML = {jsonSidecar ? true}: yamlFile: let
    yamlFileStr = toString yamlFile;
    jsonFile = removeSuffix ".yaml" (removeSuffix ".yml" yamlFileStr) + ".json";
    jsonExists = jsonSidecar && builtins.pathExists jsonFile;
  in
    if jsonExists
    then builtins.fromJSON (builtins.readFile jsonFile)
    else
      builtins.fromJSON (builtins.readFile (pkgs.runCommand "yaml-to-json" {
          nativeBuildInputs = [pkgs.yq-go];
        }
        "yq -o=json '.' ${yamlFile} > $out"));

  /**
  Filter an attribute set so that it is returned only when the
  evaluation `system` is included in `systems`.

  Example:

  ```nix
  myLib.onlyOnSystems ["x86_64-linux" "aarch64-linux"] pkgs.system {
    foo = ...;
  }
  ```
  will yield the `foo` attribute only on the listed systems.
  */
  onlyOnSystems = systems: system: attrs:
    optionalAttrs (elem system systems) attrs;

  /**
  Filter an attribute set of packages using each package's
  `meta.platforms` field. Packages without a `meta.platforms`
  specification are kept.

  Example:

  ```nix
  myLib.filterByPlatforms pkgs.system {
    foo = pkgs.callPackage ./foo {};
    bar = pkgs.callPackage ./bar {};
  }
  ```
  will omit any package whose `meta.platforms` list does not
  include the current system.
  */
  filterByPlatforms = system: attrs:
    filterAttrs (_: pkg: let
      pls = attrByPath ["meta" "platforms"] platforms.all pkg;
    in
      elem system pls)
    attrs;

  # Default exclude patterns for code quality tools.
  #
  # Note: treefmt uses glob patterns, while mypy uses regular expressions.
  # References:
  # - https://treefmt.com/latest/getting-started/configure/ (excludes are glob patterns)
  # - https://mypy.readthedocs.io/en/stable/config_file.html (exclude is a regex)
  #
  # Example:
  #
  # myLib.defaultExcludes.treefmt
  # => ["node_modules/**" "dist/**" ".direnv/**" ".jj/**" ".venv/**" "__pycache__/**" "/nix/**"]
  #
  # myLib.defaultExcludes.preCommit
  # => ["/node_modules/" "/dist/" "/.direnv/" "/.jj/" "/.venv/" "/__pycache__/" "^nix/"]
  defaultExcludeDirs = [
    {name = "node_modules";}
    {name = "dist";}
    {name = ".direnv";}
    {name = ".jj";}
    {name = ".venv";}
    {name = "__pycache__";}
    {
      name = "nix";
      rootOnly = true;
    }
  ];

  treefmtExcludesFromDirs = dirs:
    map (dir: let
      rootOnly = dir.rootOnly or false;
    in
      if rootOnly
      then "/${dir.name}/**"
      else "${dir.name}/**")
    dirs;

  preCommitExcludesFromDirs = dirs:
    map (dir: let
      rootOnly = dir.rootOnly or false;
      name = escapeRegex dir.name;
    in
      if rootOnly
      then "^${name}/"
      else "/${name}/")
    dirs;

  defaultExcludes = {
    treefmt = treefmtExcludesFromDirs defaultExcludeDirs;
    preCommit = preCommitExcludesFromDirs defaultExcludeDirs;
  };
}
