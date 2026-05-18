{
  lib,
  packageFixes ? {},
  setuptoolsPackages ? [],
}: final: prev: let
  packageNames = lib.unique (builtins.attrNames packageFixes ++ setuptoolsPackages);

  resolvePythonPackage = packageName: depName:
    if builtins.hasAttr depName final
    then builtins.getAttr depName final
    else throw "jackpkgs.python.buildFixes.${packageName}.pythonNativeBuildInputs references unknown Python package '${depName}'";

  mkFix = packageName: let
    explicit = packageFixes.${packageName} or {};
  in {
    pythonNativeBuildInputs = lib.unique (
      (lib.optional (builtins.elem packageName setuptoolsPackages) "setuptools")
      ++ (explicit.pythonNativeBuildInputs or [])
    );
    nativeBuildInputs = explicit.nativeBuildInputs or [];
  };

  overridePackage = packageName:
    if !(builtins.hasAttr packageName prev)
    then null
    else let
      fix = mkFix packageName;
      resolvedPythonNativeBuildInputs = map (resolvePythonPackage packageName) fix.pythonNativeBuildInputs;
    in
      lib.nameValuePair packageName (prev.${packageName}.overrideAttrs (old: {
        nativeBuildInputs =
          (old.nativeBuildInputs or [])
          ++ resolvedPythonNativeBuildInputs
          ++ fix.nativeBuildInputs;
      }));

  pairs = builtins.filter (pair: pair != null) (map overridePackage packageNames);
in
  builtins.listToAttrs pairs
