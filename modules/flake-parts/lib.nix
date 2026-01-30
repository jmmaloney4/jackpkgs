{jackpkgsInputs}: {lib, ...}: {
  _module.args.jackpkgsLib = {
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
