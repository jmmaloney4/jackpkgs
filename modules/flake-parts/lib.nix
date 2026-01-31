{jackpkgsInputs}: {
  lib,
  pkgs,
  ...
}: let
  nodejsValidation = import ../../lib/nodejs.nix {inherit lib;};
in {
  _module.args.jackpkgsLib = {
    nodejs =
      {
        # Shell script snippet to find node_modules/.bin
        # pathVar: name of shell variable to export/set
        # storePath: nix store path to search in
        findNodeModulesBin = pathVar: storePath: ''
          if [ -d "${storePath}/node_modules/.bin" ]; then
            ${pathVar}="${storePath}/node_modules/.bin"
          elif [ -d "${storePath}/lib/node_modules/.bin" ]; then
            ${pathVar}="${storePath}/lib/node_modules/.bin"
          elif [ -d "${storePath}/lib/node_modules/default/node_modules/.bin" ]; then
            ${pathVar}="${storePath}/lib/node_modules/default/node_modules/.bin"
          fi
        '';

        # Shell script snippet to find root of node_modules
        # rootVar: name of shell variable to set to root
        # storePath: nix store path to search in
        findNodeModulesRoot = rootVar: storePath: ''
          if [ -d "${storePath}/node_modules" ]; then
            ${rootVar}="${storePath}/node_modules"
          elif [ -d "${storePath}/lib/node_modules/default/node_modules" ]; then
            ${rootVar}="${storePath}/lib/node_modules/default/node_modules"
          elif [ -d "${storePath}/lib/node_modules" ]; then
            ${rootVar}="${storePath}/lib/node_modules"
          fi
        '';

        # Merge in validation functions from lib/nodejs.nix (ADR-022)
      }
      // nodejsValidation;
  };
}
