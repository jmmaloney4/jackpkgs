{jackpkgsInputs}: {lib, ...}: {
  _module.args.jackpkgsLib = {
    lockfileIsCacheable = lockfile: let
      lockfileVersion = lockfile.lockfileVersion or 1;
      isV3 = lockfileVersion == 3;
      packages = lockfile.packages or {};
      isWorkspaceLink = pkg: (pkg.link or false) == true;
      isCacheable = name: pkg:
        name == "" || isWorkspaceLink pkg || ((pkg ? resolved) && (pkg ? integrity));
      uncacheablePackages =
        if isV3
        then lib.filterAttrs (name: pkg: !isCacheable name pkg) packages
        else {};
      uncacheableNames = lib.attrNames uncacheablePackages;
    in {
      valid = (!isV3) || (uncacheableNames == []);
      uncacheablePackages = uncacheableNames;
      skipped = !isV3;
    };

    nodejs = {
      # Shell script snippet to find node_modules/.bin
      # pathVar: name of the shell variable to export/set
      # storePath: the nix store path to search in
      findNodeModulesBin = pathVar: storePath: ''
        if [ -d "${storePath}/node_modules/.bin" ]; then
          ${pathVar}="${storePath}/node_modules/.bin"
        elif [ -d "${storePath}/lib/node_modules/.bin" ]; then
          ${pathVar}="${storePath}/lib/node_modules/.bin"
        elif [ -d "${storePath}/lib/node_modules/default/node_modules/.bin" ]; then
          ${pathVar}="${storePath}/lib/node_modules/default/node_modules/.bin"
        fi
      '';

      # Shell script snippet to find the root of node_modules
      # rootVar: name of the shell variable to set to the root
      # storePath: the nix store path to search in
      findNodeModulesRoot = rootVar: storePath: ''
        if [ -d "${storePath}/node_modules" ]; then
          ${rootVar}="${storePath}/node_modules"
        elif [ -d "${storePath}/lib/node_modules/default/node_modules" ]; then
          ${rootVar}="${storePath}/lib/node_modules/default/node_modules"
        elif [ -d "${storePath}/lib/node_modules" ]; then
          ${rootVar}="${storePath}/lib/node_modules"
        fi
      '';
    };
  };
}
