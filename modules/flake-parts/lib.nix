{jackpkgsInputs}: {
  pkgs,
  lib,
  ...
}: {
  _module.args.jackpkgsLib =
    (import ../../lib/nodejs-helpers.nix {inherit lib;})
    // (import ../../lib {inherit pkgs;});
}
