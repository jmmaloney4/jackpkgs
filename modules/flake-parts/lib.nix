{jackpkgsInputs}: {lib, ...}: {
  _module.args.jackpkgsLib = import ../lib/nodejs-helpers.nix {inherit lib;};
}
